import Foundation

enum SocketControlMode: String, CaseIterable, Identifiable {
    case off
    case notifications
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .notifications:
            return "Notifications only"
        case .full:
            return "Full control"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Disable the local control socket."
        case .notifications:
            return "Allow only notification commands over the local socket."
        case .full:
            return "Allow all socket commands, including tab and input control."
        }
    }
}

struct SocketControlSettings {
    static let appStorageKey = "socketControlMode"
    static let legacyEnabledKey = "socketControlEnabled"

    static var defaultMode: SocketControlMode {
#if DEBUG
        return .full
#else
        return .notifications
#endif
    }

    static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CMUX_SOCKET_PATH"], !override.isEmpty {
            return override
        }
#if DEBUG
        return "/tmp/cmuxterm-debug.sock"
#else
        return "/tmp/cmuxterm.sock"
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
        return SocketControlMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func effectiveMode(userMode: SocketControlMode) -> SocketControlMode {
        if let overrideEnabled = envOverrideEnabled() {
            if !overrideEnabled {
                return .off
            }
            if let overrideMode = envOverrideMode() {
                return overrideMode
            }
            return userMode == .off ? .notifications : userMode
        }

        if let overrideMode = envOverrideMode() {
            return overrideMode
        }

        return userMode
    }
}
