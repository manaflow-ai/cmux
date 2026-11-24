#if os(iOS) && DEBUG
import SwiftUI

/// Work counters a test reads from the screen it hosts (`.environment(\.renderProbe, probe)`):
/// each test its own, so tests that run at once do not count each other's work.
@MainActor
final class RenderProbe {
    /// The Event Inspector list's body evaluations.
    var inspectorListBodies = 0
    /// The inspector's UIKit list: snapshot applies, and the rows the last one changed.
    var inspectorApplies = 0
    var inspectorLastChanged = 0
    /// The Subagents list's row evaluations, and its running clocks' draws.
    var subagentRowBodies = 0
    var subagentClockTicks = 0
}

private struct RenderProbeKey: EnvironmentKey {
    static let defaultValue: RenderProbe? = nil
}

extension EnvironmentValues {
    var renderProbe: RenderProbe? {
        get { self[RenderProbeKey.self] }
        set { self[RenderProbeKey.self] = newValue }
    }
}
#endif
