import CoreGraphics
import Foundation
import Bonsplit
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Surface resume approval persistence
enum SurfaceResumeApprovalStore {
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

    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["CMUX_SURFACE_RESUME_APPROVAL_STORE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: false)
        }
        return URL(fileURLWithPath: CmuxSettingsFileStore.defaultPrimaryPath, isDirectory: false)
    }

    static func loadRecords(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        defaultSettingsURL: URL = defaultURL()
    ) -> [SurfaceResumeApprovalRecord] {
        if storesRecordsInCmuxSettings(fileURL) {
            let loaded = loadRecordsFromCmuxSettings(fileURL: fileURL)
            if loaded.hasResumeCommandsKey {
                return loaded.records
            }
            guard fileURL.standardizedFileURL.path == defaultSettingsURL.standardizedFileURL.path else {
                return loaded.records
            }
            let legacyURL = legacyURL(forCmuxSettingsURL: fileURL)
            let legacyRecords = loadStandaloneRecords(fileURL: legacyURL, fileManager: fileManager)
            guard !legacyRecords.isEmpty else {
                return loaded.records
            }
            guard loaded.canWriteSettings else {
                return legacyRecords
            }
            _ = migrateLegacyRecordsIfNeeded(
                fileURL: fileURL,
                fileManager: fileManager,
                legacyFileURL: legacyURL
            )
            return legacyRecords
        }
        return loadStandaloneRecords(fileURL: fileURL, fileManager: fileManager)
    }

    @discardableResult
    static func migrateLegacyRecordsIfNeeded(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        legacyFileURL: URL? = nil
    ) -> Bool {
        guard storesRecordsInCmuxSettings(fileURL) else {
            return false
        }
        let loaded = loadRecordsFromCmuxSettings(fileURL: fileURL)
        guard !loaded.hasResumeCommandsKey else {
            return false
        }
        guard loaded.canWriteSettings else {
            return false
        }
        let legacyURL = legacyFileURL ?? legacyURL(forCmuxSettingsURL: fileURL)
        let legacyRecords = loadStandaloneRecords(fileURL: legacyURL, fileManager: fileManager)
        guard !legacyRecords.isEmpty else {
            return false
        }
        return writeRecordsToCmuxSettings(records: legacyRecords, fileURL: fileURL, fileManager: fileManager)
    }

    private static func loadStandaloneRecords(
        fileURL: URL,
        fileManager: FileManager
    ) -> [SurfaceResumeApprovalRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        if let file = try? JSONDecoder().decode(StoredFile.self, from: data) {
            return file.records
        }
        return (try? JSONDecoder().decode([SurfaceResumeApprovalRecord].self, from: data)) ?? []
    }

    static func validRecords(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> [SurfaceResumeApprovalRecord] {
        let signingSecret = signingSecret ?? defaultSigningSecret(fileManager: fileManager)
        guard let signingSecret else { return [] }
        return loadRecords(fileURL: fileURL, fileManager: fileManager)
            .filter { $0.hasValidSignature(secret: signingSecret) }
    }

    static func matchingRecord(
        for binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeApprovalRecord? {
        validRecords(fileURL: fileURL, fileManager: fileManager, signingSecret: signingSecret)
            .filter { $0.matches(binding) }
            .sorted { lhs, rhs in
                if lhs.commandPrefix.count != rhs.commandPrefix.count {
                    return lhs.commandPrefix.count > rhs.commandPrefix.count
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    static func applyingStoredApproval(
        to binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
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
        guard let record = matchingRecord(
            for: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecret: signingSecret
        ) else {
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

    static func applyingPromptlessCLIManualApprovalIfNeeded(
        to binding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeBindingSnapshot? {
        guard binding.isCLIBinding, existingRecord == nil else {
            return nil
        }
        guard let record = approve(
            binding: binding,
            policy: .manual,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecret: signingSecret
        ) else {
            return nil
        }
        var effectiveBinding = applyingStoredApproval(
            to: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecret: signingSecret
        )
        effectiveBinding.approvalPolicy = record.policy
        effectiveBinding.approvalRecordId = record.id
        effectiveBinding.autoResume = record.policy == .auto
        return effectiveBinding
    }

    @discardableResult
    static func approve(
        binding: SurfaceResumeBindingSnapshot,
        policy: SurfaceResumeApprovalPolicy,
        commandPrefix: [String]? = nil,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeApprovalRecord? {
        let signingSecret = signingSecret ?? defaultSigningSecret(fileManager: fileManager)
        guard let signingSecret,
              let tokens = SurfaceResumeCommandCanonicalizer.tokens(from: binding.command) else {
            return nil
        }
        let prefix = commandPrefix ?? tokens
        guard !prefix.isEmpty, tokens.count >= prefix.count, Array(tokens.prefix(prefix.count)) == prefix else {
            return nil
        }
        let now = Date().timeIntervalSince1970
        let existing = matchingRecord(
            for: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecret: signingSecret
        )
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
        writeReplacing(record: record, fileURL: fileURL, fileManager: fileManager)
        return record
    }

    @discardableResult
    static func update(
        recordId: String,
        policy: SurfaceResumeApprovalPolicy? = nil,
        commandPrefix: [String]? = nil,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> Bool {
        let signingSecret = signingSecret ?? defaultSigningSecret(fileManager: fileManager)
        guard let signingSecret else { return false }
        var records = loadRecords(fileURL: fileURL, fileManager: fileManager)
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
        return write(records: records, fileURL: fileURL, fileManager: fileManager)
    }

    @discardableResult
    static func delete(
        recordId: String,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        let records = loadRecords(fileURL: fileURL, fileManager: fileManager)
            .filter { $0.id != recordId }
        return write(records: records, fileURL: fileURL, fileManager: fileManager)
    }

    @discardableResult
    static func removeAll(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        if storesRecordsInCmuxSettings(fileURL) {
            return write(records: [], fileURL: fileURL, fileManager: fileManager)
        }
        try? fileManager.removeItem(at: fileURL)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
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

    private static func writeReplacing(
        record: SurfaceResumeApprovalRecord,
        fileURL: URL,
        fileManager: FileManager
    ) {
        var records = loadRecords(fileURL: fileURL, fileManager: fileManager)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        _ = write(records: records, fileURL: fileURL, fileManager: fileManager)
    }

    @discardableResult
    private static func write(
        records: [SurfaceResumeApprovalRecord],
        fileURL: URL,
        fileManager: FileManager
    ) -> Bool {
        if storesRecordsInCmuxSettings(fileURL) {
            return writeRecordsToCmuxSettings(records: records, fileURL: fileURL, fileManager: fileManager)
        }
        return writeStandaloneRecords(records: records, fileURL: fileURL, fileManager: fileManager)
    }

    @discardableResult
    private static func writeStandaloneRecords(
        records: [SurfaceResumeApprovalRecord],
        fileURL: URL,
        fileManager: FileManager
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
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
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

    private static func loadRecordsFromCmuxSettings(
        fileURL: URL
    ) -> (records: [SurfaceResumeApprovalRecord], hasResumeCommandsKey: Bool, canWriteSettings: Bool) {
        let root: [String: Any]
        switch loadCmuxSettingsRoot(fileURL: fileURL) {
        case .missing:
            return ([], false, true)
        case .invalid:
            return ([], false, false)
        case .parsed(let parsedRoot):
            root = parsedRoot
        }
        guard let terminalSection = root[settingsTerminalSectionKey] as? [String: Any],
              let rawRecords = terminalSection[settingsRecordsKey] else {
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
    private static func writeRecordsToCmuxSettings(
        records: [SurfaceResumeApprovalRecord],
        fileURL: URL,
        fileManager: FileManager
    ) -> Bool {
        do {
            let rootLoadResult = loadCmuxSettingsRoot(fileURL: fileURL)

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
                    "$schema": CmuxSettingsFileStore.schemaURLString,
                    "schemaVersion": CmuxSettingsFileStore.currentSchemaVersion,
                    settingsTerminalSectionKey: [
                        settingsRecordsKey: recordsValue,
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
                          parentKey: settingsTerminalSectionKey,
                          childKey: settingsRecordsKey,
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
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
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

