import CmuxMobileShellModel
import Foundation

/// The last authoritative workstream-feed list received from one Mac.
struct AgentFeedMacSnapshot {
    var revision: Int
    var items: [MobileAgentFeedItem]
}
