import Foundation
#if canImport(Security)
import Security
#endif

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
            return "Require socket authentication with a password stored in a local file."
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
    static let directoryName = "cmux"
    static let fileName = "socket-control-password"
    private static let keychainMigrationDefaultsKey = "socketControlPasswordMigrationVersion"
    private static let keychainMigrationVersion = 1
    private static let legacyKeychainService = "com.cmuxterm.app.socket-control"
    private static let legacyKeychainAccount = "local-socket-password"
    private struct LazyKeychainFallbackCache {
        var hasLoaded = false
        var password: String?
    }
    private static let lazyKeychainFallbackLock = NSLock()
    private static var lazyKeychainFallbackCache = LazyKeychainFallbackCache()

    static func configuredPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        allowLazyKeychainFallback: Bool = false,
        loadKeychainPassword: () -> String? = { loadLegacyPasswordFromKeychain() }
    ) -> String? {
        if let envPassword = normalized(environment[SocketControlSettings.socketPasswordEnvKey]) {
            return envPassword
        }
        let filePassword: String?
        do {
            filePassword = try loadPassword(fileURL: fileURL)
        } catch {
            filePassword = nil
        }
        if let filePassword {
            return filePassword
        }
        guard allowLazyKeychainFallback else {
            return nil
        }
        return cachedLazyKeychainFallbackPassword(loadKeychainPassword: loadKeychainPassword)
    }

    static func hasConfiguredPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        allowLazyKeychainFallback: Bool = false,
        loadKeychainPassword: () -> String? = { loadLegacyPasswordFromKeychain() }
    ) -> Bool {
        guard let configured = configuredPassword(
            environment: environment,
            fileURL: fileURL,
            allowLazyKeychainFallback: allowLazyKeychainFallback,
            loadKeychainPassword: loadKeychainPassword
        ) else { return false }
        return !configured.isEmpty
    }

    static func verify(
        password candidate: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        allowLazyKeychainFallback: Bool = false,
        loadKeychainPassword: () -> String? = { loadLegacyPasswordFromKeychain() }
    ) -> Bool {
        guard let expected = configuredPassword(
            environment: environment,
            fileURL: fileURL,
            allowLazyKeychainFallback: allowLazyKeychainFallback,
            loadKeychainPassword: loadKeychainPassword
        ), !expected.isEmpty else {
            return false
        }
        return expected == candidate
    }

    static func migrateLegacyKeychainPasswordIfNeeded(
        defaults: UserDefaults = .standard,
        fileURL: URL? = nil,
        loadLegacyPassword: () -> String? = { loadLegacyPasswordFromKeychain() },
        deleteLegacyPassword: () -> Bool = { deleteLegacyPasswordFromKeychain() }
    ) {
        guard defaults.integer(forKey: keychainMigrationDefaultsKey) < keychainMigrationVersion else {
            return
        }

        guard let legacyPassword = normalized(loadLegacyPassword()) else {
            defaults.set(keychainMigrationVersion, forKey: keychainMigrationDefaultsKey)
            return
        }

        do {
            if try loadPassword(fileURL: fileURL) == nil {
                try savePassword(legacyPassword, fileURL: fileURL)
            }
            guard deleteLegacyPassword() else {
                return
            }
            defaults.set(keychainMigrationVersion, forKey: keychainMigrationDefaultsKey)
        } catch {
            // Leave migration unset so it retries on next launch.
        }
    }

    static func loadPassword(fileURL: URL? = nil) throws -> String? {
        guard let fileURL = fileURL ?? defaultPasswordFileURL() else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        guard let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(password)
    }

    static func savePassword(_ password: String, fileURL: URL? = nil) throws {
        let normalized = password.trimmingCharacters(in: .newlines)
        if normalized.isEmpty {
            try clearPassword(fileURL: fileURL)
            return
        }

        guard let fileURL = fileURL ?? defaultPasswordFileURL() else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve socket password file path."]
            )
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = Data(normalized.utf8)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func clearPassword(fileURL: URL? = nil) throws {
        guard let fileURL = fileURL ?? defaultPasswordFileURL() else {
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    static func resetLazyKeychainFallbackCacheForTests() {
        lazyKeychainFallbackLock.lock()
        lazyKeychainFallbackCache = LazyKeychainFallbackCache()
        lazyKeychainFallbackLock.unlock()
    }

    static func defaultPasswordFileURL(
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        return resolvedAppSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func loadLegacyPasswordFromKeychain() -> String? {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: legacyKeychainService,
            kSecAttrAccount: legacyKeychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    private static func deleteLegacyPasswordFromKeychain() -> Bool {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: legacyKeychainService,
            kSecAttrAccount: legacyKeychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
#else
        return false
#endif
    }

    private static func cachedLazyKeychainFallbackPassword(
        loadKeychainPassword: () -> String?
    ) -> String? {
        lazyKeychainFallbackLock.lock()
        defer { lazyKeychainFallbackLock.unlock() }
        if lazyKeychainFallbackCache.hasLoaded {
            return lazyKeychainFallbackCache.password
        }
        lazyKeychainFallbackCache.hasLoaded = true
        lazyKeychainFallbackCache.password = normalized(loadKeychainPassword())
        return lazyKeychainFallbackCache.password
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
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
            "XCInjectBundle",
            "XCInjectBundleInto",
        ]
        if indicators.contains(where: { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
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
