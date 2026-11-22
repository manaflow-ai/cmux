import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextDesignTokens
import Testing

/// Lawrence 2026-11-19 (msg 40504), on the sidebar's "Did you know?" tip card: "need more padding here". The text,
/// the Try It button and the ⇧⌘P shortcut sat 6 pt (``Metrics/space3``) from the card's edges, inside the curve of
/// its 14 pt corner, and the button row sat 4 pt under the text. The tip and every other notice card hold their
/// content one card padding (``Metrics/space5``, 12 pt at the default density) in from each edge, round concentric
/// with their buttons from it, and keep the button row a row gap (``Metrics/space4``, 8 pt) under the text, at every
/// density.
@MainActor @Suite(.serialized) struct SidebarTipCardPaddingTests {
    /// The Command Palette tip as `SidebarCardFeed.noticeCard` builds it.
    static let tip = SidebarNoticeCard(
        id: "tip.palette", eyebrow: "Did you know?", title: "Command Palette", detail: "Run any cmux action by typing its name.",
        actions: [SidebarNoticeCard.Action(id: "try", title: "Try It")], shortcut: "⇧⌘P", dismissLabel: "Hide Tips")

    @Test(arguments: DensityPreset.allCases)
    func theTipCardHoldsItsContentOnePaddingInAndRoundsFromIt(density: DensityPreset) throws {
        try DensityTokens.$scoped.withValue(density.tokens) {
            let card = SidebarNoticeCardColumnTests.placed(Self.tip, sidebarWidth: 240)
            let pad = Metrics.space5, gap = Metrics.space4, b = card.bounds
            let eyebrow = try #require(SidebarNoticeCardColumnTests.label("Did you know?", in: card))
            let detail = try #require(SidebarNoticeCardColumnTests.label(Self.tip.detail ?? "", in: card))
            let shortcut = try #require(SidebarNoticeCardColumnTests.label("⇧⌘P", in: card))
            let button = try #require(card.actionButtons.first)
            let name = density.rawValue
            #expect(eyebrow.frame.minY - b.minY >= pad - 0.5, "\(name): the eyebrow is \(eyebrow.frame.minY) pt from the top, not \(pad)")
            for (label, what) in [(eyebrow, "eyebrow"), (card.titleLabel, "title"), (detail, "detail")] {
                #expect(abs(label.frame.minX - pad) <= 0.5, "\(name): the \(what) starts \(label.frame.minX) pt in, not \(pad)")
            }
            #expect(abs(button.frame.minX - pad) <= 0.5, "\(name): Try It is \(button.frame.minX) pt from the side, not \(pad)")
            #expect(abs(b.maxY - button.frame.maxY - pad) <= 0.5, "\(name): Try It is \(b.maxY - button.frame.maxY) pt from the bottom, not \(pad)")
            #expect(button.frame.minY - detail.frame.maxY >= gap - 0.5,
                    "\(name): Try It is \(button.frame.minY - detail.frame.maxY) pt under the text, not \(gap)")
            // The shortcut is right-aligned in its frame: its text ends at the frame's end.
            let shortcutStart = shortcut.frame.maxX - ceil(shortcut.attributedStringValue.size().width)
            #expect(abs(b.maxX - shortcut.frame.maxX - pad) <= 0.5, "\(name): ⇧⌘P ends \(b.maxX - shortcut.frame.maxX) pt from the side, not \(pad)")
            #expect(shortcutStart - button.frame.maxX >= gap - 0.5, "\(name): ⇧⌘P is \(shortcutStart - button.frame.maxX) pt from Try It")
            // Concentric: the card rounds by the button corner plus the padding the button sits in.
            #expect(abs(card.surface.cornerRadius - (Metrics.buttonCornerRadius + pad)) <= 0.5,
                    "\(name): the card rounds by \(card.surface.cornerRadius), not \(Metrics.buttonCornerRadius + pad)")
            let violations = ConcentricContainer.violations(child: button.frame, childRadius: Metrics.buttonCornerRadius, in: b,
                                                            outerRadius: card.surface.cornerRadius, padding: pad)
            #expect(violations.isEmpty, "\(name): \(violations)")
        }
    }
}
