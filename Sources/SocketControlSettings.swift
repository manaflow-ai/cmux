import Foundation
import Security

enum SocketControlMode: String, CaseIterable, Identifiable {
    case off
    case cmuxOnly
    case automation
    case password
    /// Full open access (all local users/processes) with no ancestry or password gate.
    case allowAll

    var id: String { rawValue }

    static var uiCases: [SocketControlMode] { [.off, .cmuxOnly, .automation, .password, .allowAll] }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .cmuxOnly:
            return "cmux processes only"
        case .automation:
            return "Automation mode"
        case .password:
            return "Password mode"
        case .allowAll:
            return "Full open access"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Disable the local control socket."
        case .cmuxOnly:
            return "Only processes started inside cmux terminals can send commands."
        case .automation:
            return "Allow external local automation clients from this macOS user (no ancestry check)."
        case .password:
            return "Require socket authentication with a password stored in your keychain."
        case .allowAll:
            return "Allow any local process and user to connect with no auth. Unsafe."
        }
    }

    var socketFilePermissions: UInt16 {
        switch self {
        case .allowAll:
            return 0o666
        case .off, .cmuxOnly, .automation, .password:
            return 0o600
        }
    }

    var requiresPasswordAuth: Bool {
        self == .password
    }
}

enum SocketControlPasswordStore {
    static let service = "com.cmuxterm.app.socket-control"
    static let account = "local-socket-password"

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizeScope(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let mappedScalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "."
        }
        var normalizedScope = String(mappedScalars)
        normalizedScope = normalizedScope.replacingOccurrences(
            of: "\\.+",
            with: ".",
            options: .regularExpression
        )
        normalizedScope = normalizedScope.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedScope
    }

    private static func scopeFromSocketPath(_ socketPath: String?) -> String? {
        guard let socketPath = normalized(socketPath) else {
            return nil
        }

        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["cmux-debug-", "cmux-"]
        for prefix in prefixes {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".sock") else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -".sock".count)
            guard start < end else { continue }
            let rawScope = String(candidate[start..<end])
            let scoped = sanitizeScope(rawScope)
            if !scoped.isEmpty {
                return scoped
            }
        }
        return nil
    }

    private static func keychainScope(environment: [String: String]) -> String? {
        if let tag = normalized(environment[SocketControlSettings.launchTagEnvKey]) {
            let scoped = sanitizeScope(tag)
            if !scoped.isEmpty {
                return scoped
            }
        }

        if let scope = scopeFromSocketPath(environment["CMUX_SOCKET_PATH"]) {
            return scope
        }

        return scopeFromSocketPath(
            SocketControlSettings.socketPath(
                environment: environment,
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
        )
    }

    private static func keychainService(environment: [String: String]) -> String {
        guard let scope = keychainScope(environment: environment) else {
            return service
        }
        return "\(service).\(scope)"
    }

    private static func baseQuery(environment: [String: String]) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService(environment: environment),
            kSecAttrAccount as String: account,
        ]
    }

    static func configuredPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let envPassword = environment[SocketControlSettings.socketPasswordEnvKey], !envPassword.isEmpty {
            return envPassword
        }
        return try? loadPassword(environment: environment)
    }

    static func hasConfiguredPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let configured = configuredPassword(environment: environment) else { return false }
        return !configured.isEmpty
    }

    static func verify(
        password candidate: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let expected = configuredPassword(environment: environment), !expected.isEmpty else {
            return false
        }
        return expected == candidate
    }

    static func loadPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String? {
        var query = baseQuery(environment: environment)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func savePassword(
        _ password: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let normalized = password.trimmingCharacters(in: .newlines)
        if normalized.isEmpty {
            try clearPassword(environment: environment)
            return
        }

        let data = Data(normalized.utf8)
        let scopedQuery = baseQuery(environment: environment)
        var lookup = scopedQuery
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var existing: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(lookup as CFDictionary, &existing)
        switch lookupStatus {
        case errSecSuccess:
            let attrsToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(scopedQuery as CFDictionary, attrsToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
            }
        case errSecItemNotFound:
            var add = scopedQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(lookupStatus))
        }
    }

    static func clearPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let status = SecItemDelete(baseQuery(environment: environment) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

struct SocketControlSettings {
    static let appStorageKey = "socketControlMode"
    static let legacyEnabledKey = "socketControlEnabled"
    static let allowSocketPathOverrideKey = "CMUX_ALLOW_SOCKET_OVERRIDE"
    static let socketPasswordEnvKey = "CMUX_SOCKET_PASSWORD"
    static let launchTagEnvKey = "CMUX_TAG"
    static let baseDebugBundleIdentifier = "com.cmuxterm.app.debug"

    private static func normalizeMode(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func parseMode(_ raw: String) -> SocketControlMode? {
        switch normalizeMode(raw) {
        case "off":
            return .off
        case "cmuxonly":
            return .cmuxOnly
        case "automation":
            return .automation
        case "password":
            return .password
        case "allowall", "openaccess", "fullopenaccess":
            return .allowAll
        // Legacy values from the old socket mode model.
        case "notifications":
            return .automation
        case "full":
            return .allowAll
        default:
            return nil
        }
    }

    /// Map persisted values to the current enum values.
    static func migrateMode(_ raw: String) -> SocketControlMode {
        parseMode(raw) ?? defaultMode
    }

    static var defaultMode: SocketControlMode {
        return .cmuxOnly
    }

    private static var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func launchTag(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[launchTagEnvKey] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func shouldBlockUntaggedDebugLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild
    ) -> Bool {
        guard isDebugBuild else { return false }
        if isRunningUnderXCTest(environment: environment) {
            return false
        }
        // XCUITest launches the app as a separate process without XCTest env vars,
        // so isRunningUnderXCTest() misses it. Check for any CMUX_UI_TEST_ env var.
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            return false
        }

        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            return false
        }

        if bundleIdentifier.hasPrefix("\(baseDebugBundleIdentifier).") {
            return false
        }

        guard bundleIdentifier == baseDebugBundleIdentifier else {
            return false
        }

        return launchTag(environment: environment) == nil
    }

    static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        let indicators = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
            "XCInjectBundleInto",
        ]
        return indicators.contains { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild
    ) -> String {
        let fallback = defaultSocketPath(bundleIdentifier: bundleIdentifier, isDebugBuild: isDebugBuild)

        guard let override = environment["CMUX_SOCKET_PATH"], !override.isEmpty else {
            return fallback
        }

        if shouldHonorSocketPathOverride(
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            isDebugBuild: isDebugBuild
        ) {
            return override
        }

        return fallback
    }

    static func defaultSocketPath(bundleIdentifier: String?, isDebugBuild: Bool) -> String {
        if bundleIdentifier == "com.cmuxterm.app.nightly" {
            return "/tmp/cmux-nightly.sock"
        }
        if isDebugLikeBundleIdentifier(bundleIdentifier) || isDebugBuild {
            return "/tmp/cmux-debug.sock"
        }
        if isStagingBundleIdentifier(bundleIdentifier) {
            return "/tmp/cmux-staging.sock"
        }
        return "/tmp/cmux.sock"
    }

    static func shouldHonorSocketPathOverride(
        environment: [String: String],
        bundleIdentifier: String?,
        isDebugBuild: Bool
    ) -> Bool {
        if isTruthy(environment[allowSocketPathOverrideKey]) {
            return true
        }
        if isDebugLikeBundleIdentifier(bundleIdentifier) || isStagingBundleIdentifier(bundleIdentifier) {
            return true
        }
        return isDebugBuild
    }

    static func isDebugLikeBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.cmuxterm.app.debug"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.")
    }

    static func isStagingBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.cmuxterm.app.staging"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.staging.")
    }

    static func isTruthy(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    static func envOverrideEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool? {
        guard let raw = environment["CMUX_SOCKET_ENABLE"], !raw.isEmpty else {
            return nil
        }

        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    static func envOverrideMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SocketControlMode? {
        guard let raw = environment["CMUX_SOCKET_MODE"], !raw.isEmpty else {
            return nil
        }
        return parseMode(raw)
    }

    static func effectiveMode(
        userMode: SocketControlMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SocketControlMode {
        if let overrideEnabled = envOverrideEnabled(environment: environment) {
            if !overrideEnabled {
                return .off
            }
            if let overrideMode = envOverrideMode(environment: environment) {
                return overrideMode
            }
            return userMode == .off ? .cmuxOnly : userMode
        }

        if let overrideMode = envOverrideMode(environment: environment) {
            return overrideMode
        }

        return userMode
    }
}
