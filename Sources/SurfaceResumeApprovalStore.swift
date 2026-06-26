import CmuxSettings
import Foundation
#if canImport(Security)
import Security
#endif

/// Persists surface-resume approval records to the cmux settings file (or a
/// standalone JSON file) and the HMAC signing secret to the Keychain.
///
/// This is the constructor-injected instance form of the former all-static
/// `SurfaceResumeApprovalStore` namespace. The storage location
/// (`fileURL`), the `FileManager`, the legacy-migration anchor
/// (`defaultSettingsURL`), and the optional explicit signing secret are injected
/// at construction; the previously per-call defaulted parameters became stored
/// state. Pure, location-independent helpers (`defaultURL`, the signing-secret
/// resolution, the Keychain accessors, the cmux.json parsing) remain `static`
/// because they carry no store state.
///
/// Behavior is byte-faithful to the legacy namespace: the same FS layout, the
/// same cmux.json / `resume-commands.json` legacy migration, the same Keychain
/// service/account, and the same change notification.
struct SurfaceResumeApprovalStore {
    static let didChangeNotification = Notification.Name("cmux.surfaceResumeApprovalsDidChange")
    private static let legacyFileName = "resume-commands.json"
    private static let secretFileName = ".surface-resume-approval-secret"
    private static let settingsTerminalSectionKey = "terminal"
    private static let settingsRecordsKey = "resumeCommands"
    private static let keychainService = "com.cmuxterm.app.surface-resume-approvals"
    private static let keychainAccount = "hmac-secret-v1"

    struct StoredFile: Codable {
        var version: Int
        var records: [SurfaceResumeApprovalRecord]
    }

    private enum CmuxSettingsRootLoadResult {
        case missing
        case invalid
        case parsed([String: Any])
    }

    /// The injected primary store location (the cmux settings file by default).
    let fileURL: URL
    /// The injected file manager used for all filesystem access.
    let fileManager: FileManager
    /// The canonical default settings path used to decide whether legacy
    /// `resume-commands.json` records should be migrated during a load.
    let defaultSettingsURL: URL
    /// An explicit signing secret override; when `nil` the store resolves the
    /// secret from the environment, Keychain, or a file-backed fallback.
    private let explicitSigningSecret: Data?

    init(
        fileURL: URL = SurfaceResumeApprovalStore.defaultURL(),
        fileManager: FileManager = .default,
        defaultSettingsURL: URL? = nil,
        signingSecret: Data? = nil
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.defaultSettingsURL = defaultSettingsURL ?? SurfaceResumeApprovalStore.defaultURL()
        self.explicitSigningSecret = signingSecret
    }

    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["CMUX_SURFACE_RESUME_APPROVAL_STORE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: false)
        }
        return URL(fileURLWithPath: CmuxSettingsFileStore.defaultPrimaryPath, isDirectory: false)
    }

    func loadRecords() -> [SurfaceResumeApprovalRecord] {
        if Self.storesRecordsInCmuxSettings(fileURL) {
            let loaded = loadRecordsFromCmuxSettings()
            if loaded.hasResumeCommandsKey {
                return loaded.records
            }
            guard fileURL.standardizedFileURL.path == defaultSettingsURL.standardizedFileURL.path else {
                return loaded.records
            }
            let legacyURL = Self.legacyURL(forCmuxSettingsURL: fileURL)
            let legacyRecords = loadStandaloneRecords(fileURL: legacyURL)
            guard !legacyRecords.isEmpty else {
                return loaded.records
            }
            guard loaded.canWriteSettings else {
                return legacyRecords
            }
            _ = migrateLegacyRecordsIfNeeded(legacyFileURL: legacyURL)
            return legacyRecords
        }
        return loadStandaloneRecords(fileURL: fileURL)
    }

    @discardableResult
    func migrateLegacyRecordsIfNeeded(
        legacyFileURL: URL? = nil
    ) -> Bool {
        guard Self.storesRecordsInCmuxSettings(fileURL) else {
            return false
        }
        let loaded = loadRecordsFromCmuxSettings()
        guard !loaded.hasResumeCommandsKey else {
            return false
        }
        guard loaded.canWriteSettings else {
            return false
        }
        let legacyURL = legacyFileURL ?? Self.legacyURL(forCmuxSettingsURL: fileURL)
        let legacyRecords = loadStandaloneRecords(fileURL: legacyURL)
        guard !legacyRecords.isEmpty else {
            return false
        }
        return writeRecordsToCmuxSettings(records: legacyRecords)
    }

    private func loadStandaloneRecords(
        fileURL: URL
    ) -> [SurfaceResumeApprovalRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        if let file = try? JSONDecoder().decode(StoredFile.self, from: data) {
            return file.records
        }
        return (try? JSONDecoder().decode([SurfaceResumeApprovalRecord].self, from: data)) ?? []
    }

    func validRecords() -> [SurfaceResumeApprovalRecord] {
        let signingSecret = explicitSigningSecret ?? Self.defaultSigningSecret(fileManager: fileManager)
        guard let signingSecret else { return [] }
        return loadRecords()
            .filter { $0.hasValidSignature(secret: signingSecret) }
    }

    func matchingRecord(
        for binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeApprovalRecord? {
        validRecords()
            .filter { $0.matches(binding) }
            .sorted { lhs, rhs in
                if lhs.commandPrefix.count != rhs.commandPrefix.count {
                    return lhs.commandPrefix.count > rhs.commandPrefix.count
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    func applyingStoredApproval(
        to binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeBindingSnapshot {
        if binding.isProcessDetected {
            var trustedBinding = binding
            trustedBinding.autoResume = true
            trustedBinding.approvalPolicy = .auto
            trustedBinding.approvalRecordId = nil
            return trustedBinding
        }

        if binding.isAgentHookBinding {
            var trustedBinding = binding
            trustedBinding.autoResume = binding.autoResume == true
            trustedBinding.approvalPolicy = trustedBinding.autoResume == true ? .auto : .manual
            trustedBinding.approvalRecordId = nil
            return trustedBinding
        }

        var effective = binding
        guard let record = matchingRecord(for: binding) else {
            effective.autoResume = false
            effective.approvalPolicy = .manual
            effective.approvalRecordId = nil
            return effective
        }

        effective.approvalPolicy = record.policy
        effective.approvalRecordId = record.id
        effective.autoResume = record.policy == .auto
        return effective
    }

    static func shouldPromptForProposal(
        binding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?,
        isMainThread: Bool,
        isRunningTests: Bool
    ) -> Bool {
        guard isMainThread else {
            return false
        }
        guard !isRunningTests else {
            return false
        }
        guard !binding.isCLIBinding else {
            return false
        }
        guard !binding.isProcessDetected, !binding.isAgentHookBinding else {
            return false
        }
        guard SurfaceResumeCommandCanonicalizer.tokens(from: binding.command) != nil else {
            return false
        }
        guard let existingRecord else { return true }
        return existingRecord.policy == .prompt
    }

    func applyingPromptlessCLIManualApprovalIfNeeded(
        to binding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?
    ) -> SurfaceResumeBindingSnapshot? {
        guard binding.isCLIBinding, existingRecord == nil else {
            return nil
        }
        guard let record = approve(
            binding: binding,
            policy: .manual
        ) else {
            return nil
        }
        var effectiveBinding = applyingStoredApproval(to: binding)
        effectiveBinding.approvalPolicy = record.policy
        effectiveBinding.approvalRecordId = record.id
        effectiveBinding.autoResume = record.policy == .auto
        return effectiveBinding
    }

    @discardableResult
    func approve(
        binding: SurfaceResumeBindingSnapshot,
        policy: SurfaceResumeApprovalPolicy,
        commandPrefix: [String]? = nil
    ) -> SurfaceResumeApprovalRecord? {
        let signingSecret = explicitSigningSecret ?? Self.defaultSigningSecret(fileManager: fileManager)
        guard let signingSecret,
              let tokens = SurfaceResumeCommandCanonicalizer.tokens(from: binding.command) else {
            return nil
        }
        let prefix = commandPrefix ?? tokens
        guard !prefix.isEmpty, tokens.count >= prefix.count, Array(tokens.prefix(prefix.count)) == prefix else {
            return nil
        }
        let now = Date().timeIntervalSince1970
        let existing = matchingRecord(for: binding)
        let record = SurfaceResumeApprovalRecord(
            id: existing?.id ?? UUID().uuidString.lowercased(),
            name: binding.name,
            commandPrefix: prefix,
            cwd: binding.cwd,
            environment: binding.environment,
            environmentKeys: Array((binding.environment ?? [:]).keys),
            source: binding.source,
            policy: policy,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            lastUsedAt: existing?.lastUsedAt,
            signature: nil
        ).signed(secret: signingSecret)
        writeReplacing(record: record)
        return record
    }

    @discardableResult
    func update(
        recordId: String,
        policy: SurfaceResumeApprovalPolicy? = nil,
        commandPrefix: [String]? = nil
    ) -> Bool {
        let signingSecret = explicitSigningSecret ?? Self.defaultSigningSecret(fileManager: fileManager)
        guard let signingSecret else { return false }
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.id == recordId }) else { return false }
        var record = records[index]
        guard record.hasValidSignature(secret: signingSecret) else { return false }
        if let policy {
            record.policy = policy
        }
        if let commandPrefix {
            guard !commandPrefix.isEmpty else { return false }
            record.commandPrefix = commandPrefix
        }
        record.updatedAt = Date().timeIntervalSince1970
        records[index] = record.signed(secret: signingSecret)
        return write(records: records)
    }

    @discardableResult
    func delete(
        recordId: String
    ) -> Bool {
        let records = loadRecords()
            .filter { $0.id != recordId }
        return write(records: records)
    }

    @discardableResult
    func removeAll() -> Bool {
        if Self.storesRecordsInCmuxSettings(fileURL) {
            return write(records: [])
        }
        try? fileManager.removeItem(at: fileURL)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return true
    }

    static func isValid(_ record: SurfaceResumeApprovalRecord, signingSecret: Data? = defaultSigningSecret()) -> Bool {
        guard let signingSecret else { return false }
        return record.hasValidSignature(secret: signingSecret)
    }

    static func defaultSigningSecret(fileManager: FileManager = .default) -> Data? {
        let env = ProcessInfo.processInfo.environment
        if let encoded = env["CMUX_SURFACE_RESUME_APPROVAL_SECRET_B64"],
           let data = Data(base64Encoded: encoded),
           !data.isEmpty {
            return data
        }
        if let data = keychainSecret(), !data.isEmpty {
            return data
        }
        let generated = randomSecret()
        if storeKeychainSecret(generated) {
            return generated
        }
        return fileBackedSecret(fileManager: fileManager, generated: generated)
    }

    private func writeReplacing(
        record: SurfaceResumeApprovalRecord
    ) {
        var records = loadRecords()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        _ = write(records: records)
    }

    @discardableResult
    private func write(
        records: [SurfaceResumeApprovalRecord]
    ) -> Bool {
        if Self.storesRecordsInCmuxSettings(fileURL) {
            return writeRecordsToCmuxSettings(records: records)
        }
        return writeStandaloneRecords(records: records)
    }

    @discardableResult
    private func writeStandaloneRecords(
        records: [SurfaceResumeApprovalRecord]
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(StoredFile(version: 1, records: records))
            try data.write(to: fileURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            return true
        } catch {
            return false
        }
    }

    private static func storesRecordsInCmuxSettings(_ fileURL: URL) -> Bool {
        fileURL.lastPathComponent == "cmux.json"
    }

    private static func legacyURL(forCmuxSettingsURL fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(legacyFileName, isDirectory: false)
    }

    private func loadRecordsFromCmuxSettings() -> (records: [SurfaceResumeApprovalRecord], hasResumeCommandsKey: Bool, canWriteSettings: Bool) {
        let root: [String: Any]
        switch Self.loadCmuxSettingsRoot(fileURL: fileURL) {
        case .missing:
            return ([], false, true)
        case .invalid:
            return ([], false, false)
        case .parsed(let parsedRoot):
            root = parsedRoot
        }
        guard let terminalSection = root[Self.settingsTerminalSectionKey] as? [String: Any],
              let rawRecords = terminalSection[Self.settingsRecordsKey] else {
            return ([], false, true)
        }
        guard JSONSerialization.isValidJSONObject(rawRecords),
              let data = try? JSONSerialization.data(withJSONObject: rawRecords, options: []),
              let records = try? JSONDecoder().decode([SurfaceResumeApprovalRecord].self, from: data) else {
            return ([], true, true)
        }
        return (records, true, true)
    }

    private static func loadCmuxSettingsRoot(fileURL: URL) -> CmuxSettingsRootLoadResult {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return .missing
        }
        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            guard let root = try JSONSerialization.jsonObject(with: sanitized, options: []) as? [String: Any] else {
                return .invalid
            }
            return .parsed(root)
        } catch {
            return .invalid
        }
    }

    @discardableResult
    private func writeRecordsToCmuxSettings(
        records: [SurfaceResumeApprovalRecord]
    ) -> Bool {
        do {
            let rootLoadResult = Self.loadCmuxSettingsRoot(fileURL: fileURL)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let recordsData = try encoder.encode(records)
            let recordsValue = try JSONSerialization.jsonObject(with: recordsData, options: [])
            guard let recordsJSON = String(data: recordsData, encoding: .utf8) else {
                return false
            }

            let data: Data
            switch rootLoadResult {
            case .missing:
                let root: [String: Any] = [
                    "$schema": CmuxSettingsFileSchema.current.schemaURLString,
                    "schemaVersion": CmuxSettingsFileSchema.current.version,
                    Self.settingsTerminalSectionKey: [
                        Self.settingsRecordsKey: recordsValue,
                    ],
                ]
                guard JSONSerialization.isValidJSONObject(root) else {
                    return false
                }
                data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            case .invalid:
                return false
            case .parsed:
                guard let existingData = fileManager.contents(atPath: fileURL.path),
                      let decodedSource = try? JSONCParser.source(data: existingData),
                      let updatedSource = JSONCObjectEditor.setNestedObjectProperty(
                          parentKey: Self.settingsTerminalSectionKey,
                          childKey: Self.settingsRecordsKey,
                          childValueJSON: recordsJSON,
                          in: decodedSource.text
                      ) else {
                    return false
                }
                guard let updatedData = updatedSource.data(using: decodedSource.encoding) else {
                    return false
                }
                let sanitized = try JSONCParser.preprocess(data: updatedData)
                guard let root = try JSONSerialization.jsonObject(with: sanitized, options: []) as? [String: Any],
                      JSONSerialization.isValidJSONObject(root) else {
                    return false
                }
                data = updatedData
            }

            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
            try data.write(to: fileURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            return true
        } catch {
            return false
        }
    }

    private static func randomSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
#if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return Data(bytes)
        }
#endif
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }

    private static func fileBackedSecret(fileManager: FileManager, generated: Data) -> Data? {
        let url = defaultURL().deletingLastPathComponent().appendingPathComponent(secretFileName, isDirectory: false)
        if let existing = try? Data(contentsOf: url), !existing.isEmpty {
            return existing
        }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try generated.write(to: url, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return generated
        } catch {
            return nil
        }
    }

#if canImport(Security)
    private static func keychainSecret() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func storeKeychainSecret(_ secret: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: secret] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }
        var insert = query
        insert[kSecValueData as String] = secret
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
#else
    private static func keychainSecret() -> Data? { nil }
    private static func storeKeychainSecret(_ secret: Data) -> Bool { false }
#endif
}
