public import AppKit
import CmuxNextDesign

/// A tab switch that eases the pane's ground colour from the tab it leaves to the tab it shows (light to dark, dark to
/// light) under the page, so the frames before the incoming page draws are a blend instead of a cut. A HYPOTHESIS from code
/// reading, not measured on a Mac: the jarring flash is the outgoing ground against the incoming page's. The switch itself
/// is unchanged: the fade is added after the swap and runs in Core Animation, so it adds no latency.
@MainActor
public enum TabSwitchMorph {
    /// `PageTunables.tabSwitchMorph`.
    public static var isOn: Bool { PageTunables.tabSwitchMorph.value }

    /// Whether a ground change is worth easing: both known and different.
    public static func eases(from: CGColor?, to: CGColor?) -> Bool {
        guard let from, let to else { return false }
        return from != to
    }

    /// Eases `host`'s ground from `from` to `to` (`Motion.panes`, crossfade timing); nothing when fades do not animate in
    /// `window` or the ground did not change.
    public static func run(on host: NSView, from: CGColor?, to: CGColor?, in window: NSWindow?) {
        guard eases(from: from, to: to), let from, let to, let layer = host.layer, Motion.panes.animatesFades else { return }
        Motion.panes.set(layer, "backgroundColor", to: to, fade: .crossfade, from: from)
    }
}
