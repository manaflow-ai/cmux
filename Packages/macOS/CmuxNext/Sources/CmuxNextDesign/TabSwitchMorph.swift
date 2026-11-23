public import AppKit
public import CmuxNextDesignTokens

/// A tab switch that eases the pane's ground colour from the tab it leaves to the tab it shows (light to dark, dark to
/// light) under the page, so the frames before the incoming page draws are a blend instead of a cut. A HYPOTHESIS from code
/// reading, not measured on a Mac: the jarring flash is the outgoing ground against the incoming page's. The switch itself
/// is unchanged: the fade is added after the swap and runs in Core Animation, so it adds no latency.
@MainActor
public enum TabSwitchMorph {
    /// Debug Settings > Panes and Columns > "Morph between tabs". Off by default (Leo, 2026-11-22, ask-5c771af51e: "ways to morph
    /// between nearby web pages to reduce jarringness").
    public static let tunable = Tunable<Bool>.toggle(
        "pages.tabSwitchMorph", .panes, "Morph between tabs", help: "A tab switch eases the pane's background colour from the tab you leave to the tab you open (light to dark and back) instead of cutting. Adds no delay to the switch.",
        default: false, code: "TabSwitchMorph.tunable")

    public static var isOn: Bool { tunable.value }

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
