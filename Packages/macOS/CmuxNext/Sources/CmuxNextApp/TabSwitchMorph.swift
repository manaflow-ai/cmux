import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A tab switch that eases the pane's ground colour from the tab it leaves to the tab it shows (light to dark, dark to
/// light) under the page, so the frames before the incoming page draws are a blend instead of a cut. Built from a
/// hypothesis (code reading, not measured on a Mac): the jarring flash is the outgoing ground against the incoming page's.
/// The switch itself is unchanged: the animation is added after the swap and runs in Core Animation, so it adds no latency.
@MainActor
enum TabSwitchMorph {
    /// `PageTunables.tabSwitchMorph`.
    static var isOn: Bool { PageTunables.tabSwitchMorph.value }

    /// The ground animation from `from` to `to`; nil when the ground did not change (nothing to ease) or `duration` is 0.
    static func animation(from: CGColor, to: CGColor?, duration: TimeInterval) -> CABasicAnimation? {
        guard let to, duration > 0, from != to else { return nil }
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = Motion.fadeCurve
        return animation
    }

    /// Eases `host`'s ground from `from` to `to`, when fades animate in `window`.
    static func run(on host: NSView, from: CGColor, to: CGColor?, in window: NSWindow?) {
        guard Motion.panes.animatesFades, let layer = host.layer,
              let animation = animation(from: from, to: to, duration: Motion.panes.duration(.crossfade)) else { return }
        layer.add(animation, forKey: "cmux.tabSwitchMorph")
    }
}
