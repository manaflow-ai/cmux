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

    static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CMUX_SOCKET_PATH"], !override.isEmpty {
            return override
        }
#if DEBUG
        return "/tmp/cmux-debug.sock"
#else
        return "/tmp/cmux.sock"
#endif
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
