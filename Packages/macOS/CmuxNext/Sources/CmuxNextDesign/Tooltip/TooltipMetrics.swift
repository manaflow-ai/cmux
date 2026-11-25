import CoreGraphics

/// The one tooltip's measurements, native and pages (Lawrence 2026-11-20: "tooltips everywhere needs
/// to be redesigned to be better and consistent", on the composer's "Select effort ⌃⇧M"). Every
/// tooltip is one line of regular 12 pt text in the primary ink, then, when the control has a
/// shortcut, its keys on a small keycap plate (the dialogs' Linear keycap,
/// ``CmuxDialogKeycapStyle/linearKbd``), inset ``keycapInset`` from the tooltip's top, bottom and
/// end so the two corners stay concentric. Pages read the same numbers as `--tooltip-*` in
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
    /// The keycap plate: its height, its inset from the tooltip's top, bottom and trailing edge, the
    /// room each side of its glyphs, and the gap after the text.
    static let keycapHeight: CGFloat = 16
    static let keycapInset: CGFloat = 4
    static let keycapPadding: CGFloat = 4
    static let keycapGap: CGFloat = 8
    /// The keycap's corner: concentric with the tooltip's (its radius less the inset).
    static var keycapRadius: CGFloat { radius - keycapInset }
    /// The widest tooltip; longer text ends in an ellipsis (a tooltip is one line).
    static let maxWidth: CGFloat = 320
    /// The gap between the tooltip and its control, and the room kept from the screen's edges.
    static let gap: CGFloat = 4
    static let edge: CGFloat = 4
}
