import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import Testing

/// Lawrence 2026-11-18: "ring roundness needs to be dependent on which window style we're in some are rounded some
/// should not be rounded". Each chrome style has its own corners: padded and floating styles round every pane
/// (`Metrics.paneCornerRadius`), the tiled ones (dividers, no separation) square them, and the curved main pane
/// (`MainPaneCardView`) and the window round the area around the panes. A square pane's ring was square at every
/// corner, so where the pane meets the rounded card the card's clip cut the ring's corner off. The ring now takes its
/// corners from the clip it meets: square where the pane is square, the clip's own curve, concentric, where it meets one.
@MainActor @Suite struct PaneRingStyleCornerTests {
    typealias StripContent = PaneRingContentAreaTests.StripContent

    static let card = CGRect(x: 0, y: 0, width: 800, height: 500)
    static let cardRadius: CGFloat = 12
    static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    /// A rounded card that clips the panes in it, as the curved main pane does.
    static func roundedCard() -> NSView {
        let card = NSView(frame: card)
        card.wantsLayer = true
        card.layer?.masksToBounds = true
        card.layer?.cornerRadius = cardRadius
        return card
    }

    /// A pane host at `frame` in `card` (not flipped: y 0 is its bottom), its overlay framed on the same cell.
    static func host(_ content: StripContent, at frame: CGRect, in card: NSView, padding: CGFloat = 0,
                     cornerRadius: CGFloat = 0) -> PaneHostView {
        let host = PaneHostView(pane: "ring", content: content)
        card.addSubview(host)
        host.frame = frame
        host.applyShape(padding: padding, cornerRadius: cornerRadius)
        host.chrome.frame = frame
        host.applyChromeShape()
        return host
    }

    /// The leading pane of a split under a top tab strip: its content area meets the card at its bottom-leading corner
    /// only (the tabs keep the top one away from the card's curve), so only that corner rounds, with the card's radius.
    @Test func aSquarePaneRoundsOnlyTheCornerItSharesWithTheCard() {
        let card = Self.roundedCard()
        let host = Self.host(StripContent(header: 30), at: CGRect(x: 0, y: 0, width: 400, height: 500), in: card)
        #expect(host.chrome.ringCornerRadius == Self.cardRadius,
                "the ring is square where the card's \(Self.cardRadius)pt curve clips it")
        #expect(host.chrome.ringCorners == [.layerMinXMaxYCorner], "only the bottom-leading corner meets the card")
        #expect(host.chrome.attentionCornerRadius == Self.cardRadius)
        #expect(host.chrome.attentionCorners == [.layerMinXMaxYCorner])
    }

    @Test func theTrailingPaneRoundsItsBottomTrailingCorner() {
        let card = Self.roundedCard()
        let host = Self.host(StripContent(header: 30), at: CGRect(x: 400, y: 0, width: 400, height: 500), in: card)
        #expect(host.chrome.ringCornerRadius == Self.cardRadius)
        #expect(host.chrome.ringCorners == [.layerMaxXMaxYCorner])
    }

    /// A pane with no tabs that fills the card rounds all four corners with it.
    @Test func aPaneThatFillsTheCardRoundsEveryCorner() {
        let card = Self.roundedCard()
        let host = Self.host(StripContent(header: 0), at: Self.card, in: card)
        #expect(host.chrome.ringCornerRadius == Self.cardRadius)
        #expect(host.chrome.ringCorners == Self.allCorners)
    }

    /// A pane that does not reach the card's corners (the middle of three) stays square: its style's panes are square.
    @Test func aPaneAwayFromTheCardsCornersStaysSquare() {
        let card = Self.roundedCard()
        let host = Self.host(StripContent(header: 0), at: CGRect(x: 300, y: 0, width: 200, height: 500), in: card)
        #expect(host.chrome.ringCornerRadius == 0)
    }

    /// A pane inset from the card's corner by less than its radius rounds concentrically: the card's radius less the inset.
    @Test func anInsetCornerIsConcentric() {
        let card = Self.roundedCard()
        let host = Self.host(StripContent(header: 0), at: Self.card.insetBy(dx: 4, dy: 4), in: card)
        #expect(host.chrome.ringCornerRadius == Self.cardRadius - 4)
        #expect(host.chrome.ringCorners == Self.allCorners)
    }

    /// A pane that moves without changing size (a split's sibling closed beside it) takes the corners of where it is.
    @Test func aPaneThatMovesTakesItsNewCorners() {
        let card = Self.roundedCard()
        let host = Self.host(StripContent(header: 30), at: CGRect(x: 400, y: 0, width: 400, height: 500), in: card)
        host.frame.origin.x = 0
        host.chrome.frame = host.frame
        host.noteWindowFrame()
        #expect(host.chrome.ringCorners == [.layerMinXMaxYCorner])
    }

    /// A style that rounds its panes (padded, floating) keeps the pane's own radius on every corner of the ring.
    @Test func aRoundedPaneKeepsItsOwnRadius() {
        let card = Self.roundedCard()
        let host = Self.host(StripContent(header: 30), at: CGRect(x: 0, y: 0, width: 400, height: 500), in: card,
                             padding: 4, cornerRadius: 8)
        #expect(host.chrome.ringCornerRadius == 8)
        #expect(host.chrome.ringCorners == Self.allCorners)
    }

    /// Outside any rounded clip (the plain window content of a square style in fullscreen) the ring is square.
    @Test func aSquarePaneOutsideARoundedClipIsSquare() {
        let plain = NSView(frame: Self.card)
        let host = Self.host(StripContent(header: 30), at: CGRect(x: 0, y: 0, width: 400, height: 500), in: plain)
        #expect(host.chrome.ringCornerRadius == 0)
    }
}
