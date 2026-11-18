import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextRemoteView

/// One cursor (cap `cursor`): which cursor shows, telling our pointer's echo from the
/// remote moving on its own, and the wire the host speaks (cmux-rd-proto cursor.rs).
@Suite struct RemoteCursorTests {
    private static let arrow = RemoteCursorShape(id: 9, width: 2, height: 1, hotX: 1, hotY: 0,
                                                 rgba: Data([0, 0, 0, 255, 255, 255, 255, 255]))

    private func state(_ x: Double = 10, _ y: Double = 20, visible: Bool = true) -> RemoteCursorState {
        RemoteCursorState(position: CGPoint(x: x, y: y), visible: visible, shapeHash: 9, shape: Self.arrow)
    }

    // MARK: Presentation

    @Test func anOlderHostKeepsTheSystemArrowAndNoOverlay() {
        for control in [false, true] {
            let p = RemoteCursorPresentation.decide(cursor: nil, control: control, pointerInImage: true, echoesLocalPointer: true, inFrame: true)
            #expect(p == .none)
        }
    }

    @Test func fullControlOverThePictureWearsTheRemoteShapeAndDrawsNothing() {
        let p = RemoteCursorPresentation.decide(cursor: state(), control: true, pointerInImage: true, echoesLocalPointer: true, inFrame: true)
        #expect(p == RemoteCursorPresentation(local: .remoteShape, drawsOverlay: false))
    }

    @Test func aRemoteThatMovesOnItsOwnIsDrawnWhereItIs() {
        let p = RemoteCursorPresentation.decide(cursor: state(), control: true, pointerInImage: true, echoesLocalPointer: false, inFrame: true)
        #expect(p == RemoteCursorPresentation(local: .system, drawsOverlay: true))
    }

    @Test func viewOnlyAndAPointerOutsideDrawTheRemoteCursor() {
        let viewOnly = RemoteCursorPresentation.decide(cursor: state(), control: false, pointerInImage: true, echoesLocalPointer: true, inFrame: true)
        #expect(viewOnly == RemoteCursorPresentation(local: .system, drawsOverlay: true))
        let outside = RemoteCursorPresentation.decide(cursor: state(), control: true, pointerInImage: false, echoesLocalPointer: true, inFrame: true)
        #expect(outside == RemoteCursorPresentation(local: .system, drawsOverlay: true))
    }

    @Test func aHiddenOrOffscreenRemoteCursorIsNotDrawn() {
        let hidden = RemoteCursorPresentation.decide(cursor: state(visible: false), control: true, pointerInImage: true, echoesLocalPointer: true, inFrame: true)
        #expect(hidden == RemoteCursorPresentation(local: .hidden, drawsOverlay: false))
        let hiddenView = RemoteCursorPresentation.decide(cursor: state(visible: false), control: false, pointerInImage: false, echoesLocalPointer: false, inFrame: true)
        #expect(hiddenView == .none)
        let elsewhere = RemoteCursorPresentation.decide(cursor: state(), control: false, pointerInImage: false, echoesLocalPointer: false, inFrame: false)
        #expect(elsewhere == .none)
    }

    // MARK: Echo

    @Test func theRemoteTrailingAFastMoveIsStillOurPointer() {
        var echo = RemotePointerEcho()
        let t0 = ContinuousClock.now
        #expect(!echo.matches(CGPoint(x: 0, y: 0), at: t0), "nothing sent yet")
        for i in 0 ..< 10 { echo.record(CGPoint(x: Double(i * 20), y: 5), at: t0 + .milliseconds(i * 8)) }
        // The host reports a position we sent 40 ms ago, and one a pixel or two off (rounding).
        #expect(echo.matches(CGPoint(x: 100, y: 5), at: t0 + .milliseconds(80)))
        #expect(echo.matches(CGPoint(x: 182, y: 4), at: t0 + .milliseconds(80)))
        // A warp somewhere we never were is not.
        #expect(!echo.matches(CGPoint(x: 500, y: 300), at: t0 + .milliseconds(80)))
        // Long after, only the last position still counts.
        #expect(!echo.matches(CGPoint(x: 100, y: 5), at: t0 + .seconds(5)))
        #expect(echo.matches(CGPoint(x: 180, y: 5), at: t0 + .seconds(5)))
    }

    @Test func theEchoMemoryIsBounded() {
        var echo = RemotePointerEcho()
        let t0 = ContinuousClock.now
        for i in 0 ..< RemotePointerEcho.capacity + 10 { echo.record(CGPoint(x: Double(i * 10), y: 0), at: t0) }
        #expect(!echo.matches(CGPoint(x: 0, y: 0), at: t0), "the oldest was dropped")
        #expect(echo.last == CGPoint(x: Double((RemotePointerEcho.capacity + 9) * 10), y: 0))
    }

    // MARK: Wire

    /// A `CursorPos` datagram as cmux-rd-proto encodes it (header 16 bytes, payload 13).
    private func datagram(seq: UInt32, shape: UInt32, x: Int32, y: Int32, visible: Bool = true) -> Data {
        var bytes: [UInt8] = [1 << 4, 6, 0, 0]
        bytes += withUnsafeBytes(of: seq.littleEndian, Array.init)
        bytes += [UInt8](repeating: 0, count: 8)
        bytes += withUnsafeBytes(of: shape.littleEndian, Array.init)
        bytes += withUnsafeBytes(of: x.littleEndian, Array.init)
        bytes += withUnsafeBytes(of: y.littleEndian, Array.init)
        bytes.append(visible ? 1 : 0)
        return Data(bytes)
    }

    @Test func positionsAreLatestWinsAndNameTheirShape() throws {
        var feed = RemoteCursorFeed()
        #expect(feed.receive(datagram: Data([1 << 4, 5, 0, 0])) == .notCursor, "an input ack")
        guard case let .state(first) = feed.receive(datagram: datagram(seq: 2, shape: 9, x: -4, y: 30)) else {
            Issue.record("no state"); return
        }
        #expect(first.position == CGPoint(x: -4, y: 30))
        #expect(first.shapeHash == 9 && first.shape == nil && first.visible)
        #expect(feed.receive(datagram: datagram(seq: 1, shape: 9, x: 0, y: 0)) == .dropped, "older")
        #expect(feed.receive(datagram: datagram(seq: 2, shape: 9, x: 0, y: 0)) == .dropped, "a repeat")
        // The shape arrives after the position that named it: the state wears it now.
        let arrow = try #require(Self.arrow)
        let received = feed.receive(shape: arrow)
        let shaped = try #require(received)
        #expect(shaped.shape?.id == 9 && shaped.position == CGPoint(x: -4, y: 30))
        guard case let .state(next) = feed.receive(datagram: datagram(seq: 3, shape: 9, x: 5, y: 6, visible: false)) else {
            Issue.record("no state"); return
        }
        #expect(next.shape?.id == 9 && !next.visible)
        // Sequence numbers wrap.
        #expect(RemoteCursorFeed.isNewer(0, than: .max))
        #expect(!RemoteCursorFeed.isNewer(.max, than: 0))
    }

    @Test func aNewShapeNotYetArrivedKeepsTheLastOne() throws {
        var feed = RemoteCursorFeed()
        _ = feed.receive(shape: try #require(Self.arrow))
        _ = feed.receive(datagram: datagram(seq: 1, shape: 9, x: 1, y: 1))
        guard case let .state(state) = feed.receive(datagram: datagram(seq: 2, shape: 77, x: 2, y: 2)) else {
            Issue.record("no state"); return
        }
        #expect(state.shapeHash == 77 && state.shape?.id == 9, "no flash back to the arrow")
    }

    @Test func malformedCursorDatagramsAreDropped() {
        var feed = RemoteCursorFeed()
        var short = datagram(seq: 1, shape: 9, x: 0, y: 0)
        short.removeLast()
        #expect(feed.receive(datagram: short) == .dropped)
        var flags = datagram(seq: 1, shape: 9, x: 0, y: 0)
        flags[flags.count - 1] = 2
        #expect(feed.receive(datagram: flags) == .dropped)
        #expect(feed.current == nil)
    }

    /// The golden vector both sides read (cmux-rd-proto tests/vectors/control.json).
    @Test func theCursorShapeVectorParsesIntoAnImage() throws {
        let json = #"{"t": "cursor_shape", "shape": 3735928559, "width": 2, "height": 1, "hot_x": 1, "hot_y": 0, "rgba": "AAAA//////8="}"#
        let control = try RemoteRdControl.parse(Data(json.utf8))
        guard case let .cursorShape(message) = control else { Issue.record("not a cursor shape"); return }
        let shape = try #require(message.cursorShape)
        #expect(shape.id == 0xdead_beef)
        #expect(shape.pixelSize == CGSize(width: 2, height: 1))
        #expect(shape.hotSpot == CGPoint(x: 1, y: 0))
        let again = try RemoteRdControl.parse(try control.json())
        #expect(again == control)
    }

    @Test func shapesWhosePixelsDoNotMatchTheirSizeAreRefused() {
        #expect(RemoteCursorShape(id: 1, width: 2, height: 2, hotX: 0, hotY: 0, rgba: Data(count: 8)) == nil)
        #expect(RemoteCursorShape(id: 1, width: 0, height: 1, hotX: 0, hotY: 0, rgba: Data()) == nil)
        let side = RemoteCursorShape.maxSide + 1
        #expect(RemoteCursorShape(id: 1, width: side, height: 1, hotX: 0, hotY: 0, rgba: Data(count: side * 4)) == nil)
    }

    // MARK: Scale

    @Test func aStreamPixelShowsAtThePicturesScale() {
        let native = RemoteViewGeometry(framePixels: CGSize(width: 2000, height: 1000), bounds: CGRect(x: 0, y: 0, width: 1000, height: 500), backingScale: 2)
        #expect(native.pointsPerStreamPixel == 0.5)
        let fit = RemoteViewGeometry(framePixels: CGSize(width: 4000, height: 2000), bounds: CGRect(x: 0, y: 0, width: 1000, height: 500),
                                     backingScale: 2, scaling: .fit)
        #expect(fit.pointsPerStreamPixel == 0.25)
        #expect(fit.containsStreamPixel(0, 0) && fit.containsStreamPixel(3999, 1999))
        #expect(!fit.containsStreamPixel(-1, 0) && !fit.containsStreamPixel(4000, 0))
    }
}
