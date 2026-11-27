// DEBUG and Demo builds only: the offline duress player is never compiled into Production.
#if DEBUG
import Foundation

/// The chat side of the offline duress simulator (cmux-next-ios/design/duress-sim.md). The player
/// (`MobileDuress`, CmuxMobileLive) installs ``attach`` once at launch when the `CmuxMobileDuress`
/// folder is set; otherwise it stays nil and nothing here runs.
@MainActor
public enum AgentChatDuress {
    /// Called by every chat store as it subscribes to its source. `deliver` takes events as the
    /// source's own. The returned object keeps the playback alive; the store releases it with itself.
    public static var attach: (@MainActor (_ deliver: @escaping @MainActor (AgentSessionEvent) -> Void) -> AnyObject)?
}
#endif
