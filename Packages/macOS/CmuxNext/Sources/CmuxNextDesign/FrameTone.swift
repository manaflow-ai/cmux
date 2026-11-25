public import CmuxTheme
import Foundation

/// The two-tone frame and the gooey tab's states as one material: the content card's surface, and the theme's ink
/// washed over it at the design system's ladder shares (hq `docs/design/design-system-decisions.md`, Fills: frame 4,
/// hover 8, selected 12, every state the share of ink in the result). Leo, 2026-11-23: "proper contrast that is only
/// as contrasty as necessary and probably not much more to not fuck up themes and bgs, and then simply properly
/// unifying the transparency and/or translucency and/or highlighting of the gooey things so that it all looks
/// consistent and good".
///
/// - The frame (the sidebar, the titlebar and the tab row around the card under Subtle Tone, and the flush corner's
///   wedges): ink at ``share(base:ink:)``, the least share that moves the surface one OKLCH step (Rust's
///   cmux-config `theme_file::frame_tone`, which this mirrors and `FrameToneTests` checks against).
/// - The selected tab, its goo fillets and the bridge into the card: no wash at all, the card itself (the shade's
///   hole, ``Palette/folderTabFill``), so they are one shape and one transparency with the content.
/// - Hover, multi-selection and press on an unselected tab: ink washed over the frame to the hover and pressed rungs
///   (``wash(rung:over:)``), so each state is one ladder step on any theme and over glass alike.
/// - A dragged tab: the card's surface lifted (the floating role), so it reads as the same tab picked up.
public nonisolated struct FrameTone {
    public nonisolated init() {}
    /// The ink ladder's frame rung: the least share.
    public static let frameRung = 0.04
    /// The selected rung: the most a frame takes. A press takes it too (Leo, 2026-10-18: no brighter press tone that
    /// flashes on a click).
    public static let selectedRung = 0.12
    /// The OKLCH lightness step the frame makes from the surface: the frame rung's step on white.
    public static let step = 0.03
    private static let rounds = 24

    /// `ink` at `share` over `base`, opaque.
    public static func washed(_ base: ThemeRGB, ink: ThemeRGB, share: Double) -> ThemeRGB {
        base.withAlpha(1).mixed(toward: ink.withAlpha(1), share)
    }

    private static func lightnessStep(_ base: ThemeRGB, _ ink: ThemeRGB, _ share: Double) -> Double {
        abs(washed(base, ink: ink, share: share).oklch.lightness - base.withAlpha(1).oklch.lightness)
    }

    /// The frame's share of `ink` over `base`: the least share from the frame rung to the selected rung whose wash
    /// moves OKLCH lightness by ``step``; the selected rung when even that does not.
    public static func share(base: ThemeRGB, ink: ThemeRGB) -> Double {
        if lightnessStep(base, ink, frameRung) >= step { return frameRung }
        if lightnessStep(base, ink, selectedRung) <= step { return selectedRung }
        var low = frameRung, high = selectedRung
        for _ in 0..<rounds {
            let mid = (low + high) / 2
            if lightnessStep(base, ink, mid) >= step { high = mid } else { low = mid }
        }
        return high
    }

    /// The share of ink a state adds over a ground that already holds `under` of it, so the result holds `rung`:
    /// `(rung − under) / (1 − under)`; 0 when the ground already holds as much.
    public static func wash(rung: Double, over under: Double) -> Double {
        rung <= under || under >= 1 ? 0 : (rung - under) / (1 - under)
    }

    /// The frame's share for `tokens`: solved on the theme's background (the base a translucent window's glass and a
    /// background picture are tinted with, so the same share holds as a plain wash over them).
    public static func share(_ tokens: ThemeTokens) -> Double {
        share(base: tokens.surfaceBackground.withAlpha(1), ink: tokens.textPrimary.withAlpha(1))
    }
}
