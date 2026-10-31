import AppKit
import Testing
@testable import MessagesLabHome

/// User, 2026-10-29 (screenshot of my outlined 2-line quote with "4 Replies"): "when multiline the bottom
/// right thing doesnt look drawn well". The quote's small tail was fitted to a one-line quote's end (half
/// circle, radius 11.25 pt); a 2-line quote's end is a larger half circle (16.75 pt), so the tail's top stood
/// about 3 pt outside the end's curve and its 1 pt outline drew a knot there. Messages joins the tail into the
/// curve at every line count. These tests read the outline the row draws (`ThreadPreview.outline`): just
/// above the tail's join, the outline may reach no further toward the end than the quote's own body.
@MainActor @Suite(.serialized) struct ThreadQuoteTailJoinTests {
    static let short = "Reply-to-conversation UI is very bad."
    static let long = "make sure the highlight color across everything in the app can be customized (and is consistent) based on the user's terminal theme"

    private func preview(_ text: String, outgoing: Bool) -> ThreadPreview {
        Fixture.withRenderScale(2) {
            ThreadPreview.make(root: PartRef(messageId: "root", partIndex: 0), part: .text(text, runs: []), count: 4,
                               outgoing: outgoing, width: 628)
        }
    }

    /// How far in from the tail's end of `box` the path first covers the row at height `y` (0 at the end itself).
    private func reach(_ path: CGPath, box: CGRect, y: CGFloat, outgoing: Bool) -> CGFloat {
        var d: CGFloat = 0
        while d < box.width / 2 {
            let x = outgoing ? box.maxX - d : box.minX + d
            if path.contains(CGPoint(x: x, y: y)) { return d }
            d += 0.02
        }
        return d
    }

    @Test(arguments: [(true, false), (true, true), (false, false), (false, true)])
    func tailJoinsTheEndCurveAtEveryLineCount(outgoing: Bool, twoLines: Bool) {
        let pv = preview(twoLines ? Self.long : Self.short, outgoing: outgoing)
        #expect(pv.textLines.count == (twoLines ? 2 : 1))
        // The box as RowDraw draws it: my quote's 1 pt outline sits half a point inside.
        let full = CGRect(x: 200, y: 40, width: pv.box.width, height: pv.box.height)
        let box = outgoing ? full.insetBy(dx: 0.5, dy: 0.5) : full
        let outline = pv.outline(in: box).cgPath
        let body = BubblePath.make(body: box, outgoing: outgoing, tail: false, circularEnds: true).cgPath
        // The tail's top joins the body 2.0 to 2.4 pt above its bottom; above 1.8 pt the tail must sit inside the curve.
        var worst: CGFloat = 0, at: CGFloat = 0
        var h: CGFloat = 1.8
        while h <= 4 {
            let y = box.maxY - h
            let past = reach(body, box: box, y: y, outgoing: outgoing) - reach(outline, box: box, y: y, outgoing: outgoing)
            if past > worst { worst = past; at = h }
            h += 0.1
        }
        #expect(worst <= 0.6, "\(twoLines ? 2 : 1)-line \(outgoing ? "outgoing" : "incoming") quote: its tail stands \(worst) pt past the end's curve \(at) pt above the bottom")
    }

    /// The tail still hangs under the quote at every line count (Messages: about 4 pt), on the quote's side.
    @Test(arguments: [(true, false), (true, true), (false, false), (false, true)])
    func tailStillHangsUnderTheEnd(outgoing: Bool, twoLines: Bool) {
        let pv = preview(twoLines ? Self.long : Self.short, outgoing: outgoing)
        let box = CGRect(x: 200, y: 40, width: pv.box.width, height: pv.box.height)
        let tailBox = pv.outline(in: box).cgPath.boundingBoxOfPath
        #expect(tailBox.maxY - box.maxY >= 3.9 && tailBox.maxY - box.maxY <= 4.3, "tail drop \(tailBox.maxY - box.maxY)")
        #expect(tailBox.minX >= box.minX - 0.01 && tailBox.maxX <= box.maxX + 0.01, "the tail reaches past the quote's end")
        let tip = pv.outline(in: box).cgPath
        let under = stride(from: CGFloat(3), through: 16, by: 0.25).contains { d in
            tip.contains(CGPoint(x: outgoing ? box.maxX - d : box.minX + d, y: box.maxY + 1.5))
        }
        #expect(under, "no tail under the quote's end")
    }
}
