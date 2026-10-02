import Foundation

/// The host's live connection state to the Mac serving an artifact preview.
///
/// Transport failures read very differently depending on which side dropped:
/// when the PHONE knows its own session is down or re-forming, the copy must
/// say so instead of sending the user to inspect the Mac.
public enum ChatArtifactConnectionHint: Equatable, Sendable {
    /// The session looks healthy; a transport failure is unexpected.
    case connected
    /// The phone's session dropped and is re-establishing automatically.
    case reconnecting
    /// The phone is not connected to the Mac right now.
    case disconnected
}

extension ChatArtifactConnectionHint {
    /// Title + message for an unreachable-style failure under this hint.
    var unreachableCopy: (title: String, message: String) {
        switch self {
        case .connected:
            (
                String(localized: "chat.artifact.mac_unreachable.title", defaultValue: "Mac unreachable", bundle: .module),
                String(localized: "chat.artifact.mac_unreachable.message", defaultValue: "Check the connection to your Mac and try again.", bundle: .module)
            )
        case .reconnecting:
            (
                String(localized: "chat.artifact.reconnecting.title", defaultValue: "Reconnecting\u{2026}", bundle: .module),
                String(localized: "chat.artifact.reconnecting.message", defaultValue: "This phone's connection to the Mac dropped and is coming back. Retry in a moment.", bundle: .module)
            )
        case .disconnected:
            (
                String(localized: "chat.artifact.disconnected.title", defaultValue: "Not connected", bundle: .module),
                String(localized: "chat.artifact.disconnected.message", defaultValue: "This phone isn't connected to the Mac right now. Reconnect, then retry.", bundle: .module)
            )
        }
    }
}
