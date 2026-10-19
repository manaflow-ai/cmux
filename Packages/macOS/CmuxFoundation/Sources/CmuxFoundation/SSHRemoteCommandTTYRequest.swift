import Foundation

/// The effective OpenSSH `RequestTTY` state while applying ordered command flags.
enum SSHRemoteCommandTTYRequest: Equatable {
    case automatic
    case disabled
    case enabled
    case forced

    init(optionValue: String?) {
        switch optionValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "no", "false": self = .disabled
        case "yes", "true": self = .enabled
        case "force": self = .forced
        default: self = .automatic
        }
    }

    var optionValue: String {
        switch self {
        case .automatic: "auto"
        case .disabled: "no"
        case .enabled: "yes"
        case .forced: "force"
        }
    }
}
