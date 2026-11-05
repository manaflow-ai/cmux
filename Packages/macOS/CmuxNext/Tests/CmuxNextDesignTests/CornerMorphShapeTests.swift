import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// Debug `sidebar.cornerMorph`: the card and its attachments are one path (Leo 2026-11-05, "morph it together").
struct CornerMorphShapeTests {
    // A card at x 206 (sidebar 200 + 6 gutter), 10 pt corners, in unflipped coordinates (top = maxY).
    let card = CGRect(x: 206, y: 6, width: 600, height: 500)

    @Test func plainCardKeepsItsRoundedCorner() {
        let path = CornerMorph(rowRadius: 9, fillet: 9).surface(card: card, radius: 10)
        #expect(!path.contains(CGPoint(x: 206.5, y: 505.5))) // inside the square, outside the 10 pt arc
        #expect(path.contains(CGPoint(x: 400, y: 300)))
    }

    @Test func shellJoinsTheTitlebarRowAndSquaresTheCardCorner() {
        // The titlebar row, 40 pt tall at the top, from the 6 pt gutter to the sidebar's edge.
        let header = CGRect(x: 6, y: 466, width: 194, height: 40)
        let path = CornerMorph(header: header, rowRadius: 9, fillet: 9).surface(card: card, radius: 10)
        #expect(path.contains(CGPoint(x: 206.5, y: 505.5))) // the card's corner is covered
        #expect(path.contains(CGPoint(x: 100, y: 486)))     // the band itself
        #expect(path.contains(CGPoint(x: 203, y: 486)))     // the gutter between band and card
        // The concave fillet under the band, against the card's edge: in near the corner, out at its circle.
        #expect(path.contains(CGPoint(x: 205.5, y: 465)))
        #expect(!path.contains(CGPoint(x: 198, y: 458)))
        // The band's outer corner keeps the card's radius.
        #expect(!path.contains(CGPoint(x: 6.5, y: 505.5)))
    }

    @Test func bridgeJoinsTheSelectedRowWithFilletsAboveAndBelow() {
        let row = CGRect(x: 8, y: 300, width: 184, height: 28)
        let path = CornerMorph(row: row, rowRadius: 9, fillet: 9).surface(card: card, radius: 10)
        #expect(path.contains(CGPoint(x: 199, y: 314)))  // the gutter beside the row
        #expect(path.contains(CGPoint(x: 205.5, y: 299))) // fillet below
        #expect(path.contains(CGPoint(x: 205.5, y: 329))) // fillet above
        #expect(!path.contains(CGPoint(x: 198, y: 292)))
        #expect(!path.contains(CGPoint(x: 100, y: 340)))  // the list beside it stays chrome
    }

    @Test func rowOutsideTheCardJoinsNothing() {
        let row = CGRect(x: 8, y: 520, width: 184, height: 28)
        let path = CornerMorph(row: row, rowRadius: 9, fillet: 9).surface(card: card, radius: 10)
        #expect(!path.contains(CGPoint(x: 100, y: 530)))
    }

    @Test func rowTooNearTheCardCornerJoinsNothing() {
        // Its top end lands 8 pt under the card's top: no room for a fillet beside the 10 pt corner.
        let row = CGRect(x: 8, y: 470, width: 184, height: 28)
        let path = CornerMorph(row: row, rowRadius: 9, fillet: 9).surface(card: card, radius: 10)
        #expect(!path.contains(CGPoint(x: 100, y: 484)))
    }

    @Test func flatChromeJoinsTheFlushContentArea() {
        // The default flat chrome: the content meets the sidebar at x 200 and the window's top, square.
        let content = CGRect(x: 200, y: 0, width: 600, height: 512)
        let header = CGRect(x: 0, y: 472, width: 200, height: 40)
        let row = CGRect(x: 8, y: 300, width: 184, height: 28)
        let path = CornerMorph(header: header, row: row, rowRadius: 9, fillet: 9).surface(card: content, radius: 0)
        #expect(path.contains(CGPoint(x: 100, y: 490)))   // the titlebar row
        #expect(path.contains(CGPoint(x: 199.5, y: 471))) // the concave fillet under it
        #expect(!path.contains(CGPoint(x: 100, y: 400)))  // the list stays tinted
        #expect(path.contains(CGPoint(x: 196, y: 314)))   // the selected row's bridge
        #expect(path.contains(CGPoint(x: 199.5, y: 299))) // and its fillet
    }
}
