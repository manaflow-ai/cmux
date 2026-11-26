public import AppKit
public import CmuxNextDesignTokens

/// A tab switch that eases the pane's ground colour from the tab it leaves to the tab it shows (light to dark, dark to
/// light) under the page, so the frames before the incoming page draws are a blend instead of a cut. A HYPOTHESIS from code
/// reading, not measured on a Mac: the jarring flash is the outgoing ground against the incoming page's. The switch itself
/// is unchanged: the fade is added after the swap and runs in Core Animation, so it adds no latency.
@MainActor
public struct TabSwitchMorph {
    public init() {}
    /// Debug Settings > Panes and Columns > "Morph between tabs". Off by default (Leo, 2026-11-22, ask-5c771af51e: "ways to morph
    /// between nearby web pages to reduce jarringness").
    public nonisolated static let tunable = Tunable<Bool>.toggle(
        "pages.tabSwitchMorph", .panes, "Morph between tabs", help: "A tab switch eases the pane's background colour from the tab you leave to the tab you open (light to dark and back) instead of cutting. Adds no delay to the switch.",
        default: false, code: "TabSwitchMorph.tunable")

    public static var isOn: Bool { tunable.value }

    /// CIE L* (0 black, 100 white) of `color` in sRGB; nil when it has no RGB reading.
    public static func lightness(of color: CGColor) -> Double? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let rgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 3 else { return nil }
        func linear(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let y = 0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
        return y > 0.008856 ? 116 * cbrt(y) - 16 : 903.3 * y
    }

    /// Smallest lightness jump (|dL*| over 100) worth easing: the measured `veil+chrome` design (cmuxterm-hq
    /// docs/findings/browser-page-morph-2026-11-22.md) leaves smaller jumps untouched.
    public static let minimumJump = 0.2

    /// Whether a ground change is worth easing: both known and a big lightness jump (light to dark or back).
    public static func eases(from: CGColor?, to: CGColor?) -> Bool {
        guard let from, let to, let a = lightness(of: from), let b = lightness(of: to) else { return false }
        return abs(a - b) / 100 > minimumJump
    }

    /// Eases `host`'s ground from `from` to `to` (`Motion.panes`, crossfade timing). This is the chrome half of `veil+chrome`: a view layer cannot veil a Chromium page, whose window draws above it; nothing when fades do not animate in
    /// `window` or the ground did not change.
    public static func run(on host: NSView, from: CGColor?, to: CGColor?, in window: NSWindow?) {
        guard eases(from: from, to: to), let from, let to, let layer = host.layer, Motion.panes.animatesFades else { return }
        Motion.panes.set(layer, "backgroundColor", to: to, fade: .crossfade, from: from)
    }
}

extension PaneContentAreaView {
    /// Runs `swap` (a tab switch), then eases this area's ground from the one it showed before to the one it shows now
    /// when `on` (``TabSwitchMorph``).
    public func easesGround(_ on: Bool, _ swap: () -> Void) {
        let from = on ? groundColor : nil
        swap()
        if on { TabSwitchMorph.run(on: self, from: from, to: groundColor, in: window) }
    }
}
