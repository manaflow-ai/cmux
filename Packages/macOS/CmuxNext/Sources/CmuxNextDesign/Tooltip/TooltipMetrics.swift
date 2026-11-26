import CoreGraphics

/// The one tooltip's measurements, native and pages (Lawrence 2026-11-20: "tooltips everywhere needs
/// to be redesigned to be better and consistent", on the composer's "Select effort ⌃⇧M"). Every
/// tooltip is one line of regular 12 pt text in the primary ink, then, when the control has a
/// shortcut, its keys as plain glyphs in the secondary ink, no plate, as a macOS menu writes them
/// (``CmuxDialogKeycapStyle/plainGlyph``; Leo 2026-11-22 on the plate: "a bullshit looking fucking
/// command icon"; the web's one key hint, webviews/src/ui/KeyHint.tsx). Pages read the same numbers as `--tooltip-*` in
/// webviews/src/pages/shared/desktop.css; webviews/test/tooltip-metrics.test.ts fails when the two
/// drift. Values are points at Interface Size 1; ``scaled(_:)`` follows the person's size.
nonisolated struct TooltipMetrics: Sendable {
    /// The text's size and line height (`TypeScale.Base.detail`).
    static let fontSize: CGFloat = 12
    static let lineHeight: CGFloat = 16
    /// Room above and below the text.
    static let paddingBlock: CGFloat = 4
    /// Room before the text, and after it when there is no keycap.
    static let paddingInline: CGFloat = 8
    /// The surface's corner.
    static let radius: CGFloat = 8
    /// The gap between the text and the shortcut's keys; the keys end at ``paddingInline``.
    static let keycapGap: CGFloat = 8
    /// The widest tooltip; longer text ends in an ellipsis (a tooltip is one line).
    static let maxWidth: CGFloat = 320
    /// The gap between the tooltip and its control, and the room kept from the screen's edges.
    static let gap: CGFloat = 4
    static let edge: CGFloat = 4
}
