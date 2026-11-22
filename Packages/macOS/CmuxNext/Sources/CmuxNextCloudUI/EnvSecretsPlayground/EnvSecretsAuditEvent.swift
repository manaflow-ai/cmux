#if DEBUG
import AppKit

/// DEBUG ONLY (Environment Secrets Playground): one line of a secret's history. It never holds the value.
struct EnvSecretsAuditEvent: Identifiable {
    enum Outcome {
        case sent, blocked, hostAdded, replaced, created, revoked

        var title: String {
            switch self {
            case .sent: "Sent"
            case .blocked: "Blocked"
            case .hostAdded: "Host added"
            case .replaced: "New value"
            case .created: "Created"
            case .revoked: "Revoked"
            }
        }

        var symbol: String {
            switch self {
            case .sent: "arrow.up.right"
            case .blocked: "hand.raised"
            case .hostAdded: "plus.circle"
            case .replaced: "arrow.triangle.2.circlepath"
            case .created: "sparkle"
            case .revoked: "xmark.octagon"
            }
        }

        var tint: NSColor {
            switch self {
            case .sent: NSColor.systemGreen
            case .blocked, .revoked: NSColor.systemRed
            case .hostAdded: NSColor.systemOrange
            case .replaced, .created: NSColor.secondaryLabelColor
            }
        }
    }

    var id: Int
    var time: String
    var outcome: Outcome
    /// The chat or person, as a readable name.
    var who: String
    var host: String
    var detail: String
}
#endif
