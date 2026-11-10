import AppKit
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// While another view sets a terminal's grid smaller than this pane ("Sized for"), the pane space the
/// grid does not use is hatched as in cmux-classic (`TerminalSizeBoundsOverlayView`): 0.5 pt lines
/// rising at 45°, 8 pt apart, cut out over the grid (user, Nov 9: "we should better match cmux-classic
/// which draws a bunch of diagonal lines"). Only the chip showed before.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalSizedForHatchTests {
    /// The visible hatch: a shape layer of 0.5 pt lines with an even-odd mask, anywhere under `view`.
    private static func hatch(in view: NSView) -> (lines: CAShapeLayer, origin: CGPoint, owner: NSView)? {
        for sub in [view] + view.subviews {
            if sub !== view, let found = hatch(in: sub) { return found }
            guard !sub.isHiddenOrHasHiddenAncestor, let layers = sub.layer?.sublayers else { continue }
            for case let shape as CAShapeLayer in layers
            where shape.lineWidth == 0.5 && !shape.isHidden && (shape.mask as? CAShapeLayer)?.fillRule == .evenOdd {
                return (shape, .zero, sub)
            }
        }
        return nil
    }

    private static func segments(_ path: CGPath) -> [(CGPoint, CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        var start = CGPoint.zero
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: start = e.points[0]
            case .addLineToPoint: out.append((start, e.points[0]))
            default: break
            }
        }
        return out
    }

    @Test func theSpaceTheGridDoesNotUseIsHatchedLikeClassic() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = HatchScriptedIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { io.finish(); window.close() }
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        io.send(.status(.connected))
        io.send(.sizedFor(TerminalSizedFor(deviceName: "Maya's iPhone", deviceKind: "iphone", sameDevice: false,
                                           grid: TerminalGridSize(columns: 20, rows: 5))))
        var turns = 0
        while session.view.sizedForText == nil, turns < 20_000 { await Task.yield(); turns += 1 }
        try #require(session.view.sizedForText != nil, "the chip never showed")
        session.view.layoutSubtreeIfNeeded()

        let found = try #require(Self.hatch(in: session.view), "no hatch outside the 20×5 grid")
        let mask = try #require((found.lines.mask as? CAShapeLayer)?.path)
        let area = found.owner.bounds
        // The bottom-trailing corner is outside a 20×5 grid; a point just inside the top-leading cell is in it.
        #expect(mask.contains(CGPoint(x: area.maxX - 4, y: area.minY + 4), using: .evenOdd), "the unused corner is not hatched")
        let origin = session.view.firstCellOrigin
        #expect(!mask.contains(CGPoint(x: origin.x + 3, y: area.maxY - origin.y - 3), using: .evenOdd), "the grid is hatched over")

        // Classic's lines: rising at 45°, 8 pt apart.
        let lines = try #require(found.lines.path)
        let segments = Self.segments(lines)
        try #require(segments.count > 2)
        for (a, b) in segments.prefix(4) { #expect(abs((b.y - a.y) - (b.x - a.x)) < 0.001 && b.y > a.y) }
        #expect(segments[1].0.x - segments[0].0.x == 8)
    }
}

/// A scripted ``TerminalIO``: the test sends its events.
private nonisolated final class HatchScriptedIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    var answersTerminalQueries: Bool { false }
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    func send(_ event: TerminalIOEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
}
