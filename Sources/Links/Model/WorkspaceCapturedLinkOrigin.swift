import CmuxTerminalCore

enum WorkspaceCapturedLinkOrigin: String, Codable, Hashable, Sendable {
    case osc8
    case detected

    init(_ source: TerminalCapturedLink.Source) {
        switch source {
        case .osc8: self = .osc8
        case .detected: self = .detected
        }
    }
}
