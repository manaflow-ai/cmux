import CoreGraphics
import Testing
@testable import CmuxHomeRender

@Suite struct BubblePathTests {
    /// Every rounded rect (continuous, capsule, short) fills its rect exactly:
    /// the bounding box is the rect, the center is inside and the very corner is not.
    @Test(arguments: [CGSize(width: 200, height: 60), CGSize(width: 200, height: 30), CGSize(width: 30, height: 200),
                      CGSize(width: 20, height: 24), CGSize(width: 46, height: 46)])
    func roundedRectFillsItsRect(size: CGSize) {
        let rect = CGRect(origin: CGPoint(x: 10, y: 20), size: size)
        let path = RoundedRect.path(rect, radius: 15)
        let box = path.boundingBoxOfPath
        #expect(abs(box.minX - rect.minX) < 0.01 && abs(box.maxX - rect.maxX) < 0.01)
        #expect(abs(box.minY - rect.minY) < 0.01 && abs(box.maxY - rect.maxY) < 0.01)
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
        #expect(!path.contains(CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5)))
        #expect(!path.contains(CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5)))
    }

    /// Continuous corners leave the straight edge 1.52866 r from the corner.
    @Test func continuousCornerStartsOnTheEdge() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let path = RoundedRect.path(rect, radius: 15)
        let k = RoundedRect.k * 15
        #expect(path.contains(CGPoint(x: k + 0.5, y: 0.25)))
        #expect(!path.contains(CGPoint(x: 2, y: 0.25)))
    }

    /// The tail hangs below the body's bottom corner on the sender's side only.
    @Test(arguments: [true, false])
    func tailHangsOnTheSendersSide(outgoing: Bool) {
        let body = CGRect(x: 100, y: 50, width: 120, height: 30)
        let plain = BubblePath.make(body: body, outgoing: outgoing, tail: false).boundingBoxOfPath
        let tailed = BubblePath.make(body: body, outgoing: outgoing, tail: true).boundingBoxOfPath
        #expect(abs(plain.maxY - body.maxY) < 0.01)
        #expect(abs(tailed.maxY - (body.maxY + BubblePath.tailDrop)) < 0.01)
        #expect(abs(tailed.minX - body.minX) < 0.01 && abs(tailed.maxX - body.maxX) < 0.01)
        #expect(abs(tailed.minY - body.minY) < 0.01)
        // The tail sits under the sender's corner.
        let path = BubblePath.make(body: body, outgoing: outgoing, tail: true)
        let x = outgoing ? body.maxX - 7.5 : body.minX + 7.5
        let far = outgoing ? body.minX + 7.5 : body.maxX - 7.5
        #expect(path.contains(CGPoint(x: x, y: body.maxY + 2.5)))
        #expect(!path.contains(CGPoint(x: far, y: body.maxY + 2.5)))
    }

    /// The tail is part of one outline (union): its tip is inside the path.
    @Test func tailTipIsFilled() {
        let body = CGRect(x: 0, y: 0, width: 120, height: 30)
        let path = BubblePath.make(body: body, outgoing: true, tail: true)
        #expect(path.contains(CGPoint(x: body.maxX - 7.5, y: body.maxY + 2.5)))
        #expect(!path.contains(CGPoint(x: body.maxX - 1, y: body.maxY + 1)))
    }
}
