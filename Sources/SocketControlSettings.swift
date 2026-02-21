import Foundation

enum SocketControlMode: String, CaseIterable, Identifiable {
    case off
    case cmuxOnly
    /// Allow any local process to connect (no ancestry check).
    /// Only accessible via CMUX_SOCKET_MODE=allowAll env var — not shown in the UI.
    case allowAll

    var id: String { rawValue }

    /// Cases shown in the Settings UI. `allowAll` is intentionally excluded.
    static var uiCases: [SocketControlMode] { [.off, .cmuxOnly] }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .cmuxOnly:
            return "cmux processes only"
        case .allowAll:
            return "Allow all processes"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Disable the local control socket."
        case .cmuxOnly:
            return "Only processes started inside cmux terminals can send commands."
        case .allowAll:
            return "Allow any local process to connect (no ancestry check)."
        }
    }
}

struct SocketControlSettings {
    static let appStorageKey = "socketControlMode"
    static let legacyEnabledKey = "socketControlEnabled"
    static let allowSocketPathOverrideKey = "CMUX_ALLOW_SOCKET_OVERRIDE"

    /// Map old persisted rawValues to the new enum.
    static func migrateMode(_ raw: String) -> SocketControlMode {
        switch raw {
        case "off": return .off
        case "cmuxOnly": return .cmuxOnly
        case "allowAll": return .allowAll
        // Legacy values:
        case "notifications", "full": return .cmuxOnly
        default: return defaultMode
        }
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

    static func envOverrideEnabled() -> Bool? {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_SOCKET_ENABLE"], !raw.isEmpty else {
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

    static func envOverrideMode() -> SocketControlMode? {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_SOCKET_MODE"], !raw.isEmpty else {
            return nil
        }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch cleaned {
        case "off": return .off
        case "cmuxonly", "cmux_only", "cmux-only": return .cmuxOnly
        case "allowall", "allow_all", "allow-all": return .allowAll
        // Legacy env var values — map to allowAll so existing test scripts keep working
        case "notifications", "full": return .allowAll
        default: return SocketControlMode(rawValue: cleaned)
        }
    }

    static func effectiveMode(userMode: SocketControlMode) -> SocketControlMode {
        if let overrideEnabled = envOverrideEnabled() {
            if !overrideEnabled {
                return .off
            }
            if let overrideMode = envOverrideMode() {
                return overrideMode
            }
            return userMode == .off ? .cmuxOnly : userMode
        }

        if let overrideMode = envOverrideMode() {
            return overrideMode
        }

        return userMode
    }
}
