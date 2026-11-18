import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import Testing

/// Lawrence 2026-11-17: "ring should only be around terminal area not the full pane (top tabs) consider roundness
/// properly too". Under Floating Panes every pane is one card, tab strip included (`PaneHostView.wholeCard`), and the
/// pane host told its overlay the card had no header, so the focus ring, its move flash and the unread ring traced
/// the whole card, around the tabs. The ring marks the content area below the tabs in every chrome style; only the
/// inactive dim covers the whole card.
@MainActor @Suite struct PaneRingContentAreaTests {
    /// Pane content with a tab strip `header` points high on top and `footer` points high below.
    final class StripContent: NSView, PaneContentChrome {
        var header: CGFloat
        var footer: CGFloat
        var onPaneHeaderHeightChange: (() -> Void)?

        init(header: CGFloat, footer: CGFloat = 0) {
            self.header = header
            self.footer = footer
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { true }
        var paneHeaderHeight: CGFloat { header }
        var paneFooterHeight: CGFloat { footer }
        func setPaneContentCornerRadius(_ radius: CGFloat) {}
    }

    static let cell = CGRect(x: 0, y: 0, width: 600, height: 400)
    static let padding: CGFloat = 4
    static let radius: CGFloat = 12

    /// A pane host at `cell` whose overlay is framed on the same cell, as the layout root places both.
    static func host(_ content: StripContent, wholeCard: Bool) -> PaneHostView {
        let host = PaneHostView(pane: "ring", content: content)
        host.frame = cell
        host.applyShape(padding: padding, cornerRadius: radius, wholeCard: wholeCard)
        host.chrome.frame = cell
        host.applyChromeShape()
        return host
    }

    /// The padded card less `top` points of tabs above and `bottom` below.
    static func contentArea(top: CGFloat, bottom: CGFloat = 0) -> CGRect {
        let card = cell.insetBy(dx: padding, dy: padding)
        return CGRect(x: card.minX, y: card.minY + top, width: card.width, height: card.height - top - bottom)
    }

    @Test(arguments: [false, true])
    func theRingTracesTheContentBelowATopStrip(wholeCard: Bool) {
        let host = Self.host(StripContent(header: 30), wholeCard: wholeCard)
        #expect(host.chrome.ringFrame == Self.contentArea(top: 30),
                "wholeCard \(wholeCard): the ring traced \(host.chrome.ringFrame), around the tabs, not the content below them")
        #expect(host.roundedRect == Self.contentArea(top: 30), "the ring's sync check reads a rect that is not the content's")
    }

    @Test(arguments: [false, true])
    func theRingTracesTheContentAboveABottomStrip(wholeCard: Bool) {
        let host = Self.host(StripContent(header: 0, footer: 28), wholeCard: wholeCard)
        #expect(host.chrome.ringFrame == Self.contentArea(top: 0, bottom: 28),
                "wholeCard \(wholeCard): the ring traced \(host.chrome.ringFrame), around the bottom tabs")
    }

    @Test func aStripThatChangesHeightMovesTheRingInAFloatingCard() {
        let content = StripContent(header: 30)
        let host = Self.host(content, wholeCard: true)
        content.header = 0
        content.onPaneHeaderHeightChange?()
        #expect(host.chrome.ringFrame == Self.contentArea(top: 0))
    }
}
