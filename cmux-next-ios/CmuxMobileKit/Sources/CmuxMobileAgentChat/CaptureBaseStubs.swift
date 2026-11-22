// DEBUG and Demo builds only. CAPTURE BASE STUBS (not product code): the seams the head's list
// rig (ListStressChatScreens) calls that the base does not have, with the base's behavior.
#if os(iOS) && DEBUG
import Foundation
import SwiftUI

/// The head's 50 Hz follow probe. The base transcript has no follow rule to measure: it never
/// reports a sample.
@MainActor @Observable
public final class FollowProbe {
    @ObservationIgnored public var armed = false
    private(set) var summary = "follow probe: base (no follow rule)"
    public init() {}
}

extension SubagentTranscriptScreen {
    /// The head's initializer: the base screen takes no probe.
    init(store: AgentChatStore, surface: AgentChatSurface, subagentID: String, probe: FollowProbe?) {
        self.init(store: store, surface: surface, subagentID: subagentID)
    }
}
#endif
