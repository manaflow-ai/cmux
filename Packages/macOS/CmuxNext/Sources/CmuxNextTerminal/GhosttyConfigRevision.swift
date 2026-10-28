public import Observation

/// The applied Ghostty config's revision. ``GhosttyRuntime`` bumps it once per
/// config change (a reload, a conditional theme switch), after the new config is in place. It
/// replaces the `configDidChange` broadcast: a view reads it through a `VisibleObservation`, which
/// tracks it only while the view's node is visible, so a reload does no work for a hidden terminal
/// and showing it reads the revision once (Chrome sends a hidden widget no visual updates until it
/// is shown: `content/browser/renderer_host/render_widget_host_impl.cc`, `WasHidden` / `WasShown`).
@MainActor @Observable
public final class GhosttyConfigRevision {
    /// The number of config changes applied so far.
    public private(set) var value: UInt64 = 0

    public init() {}

    /// Records one applied config change.
    func bump() {
        value &+= 1
    }
}
