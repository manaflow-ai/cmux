import CmuxNextRemoteView
import CmuxScreenKit
import CoreGraphics

/// The pane's input events as screen stream input: physical keys by keysym
/// (the host maps them back to its own layout), pointer in stream pixels,
/// wheel clicks, committed text.
final class MacScreenInputSink: RemoteViewInputSink {
    weak var session: ScreenSession?
    private var scroll = MacScreenScroll()

    init(session: ScreenSession) {
        self.session = session
    }

    func send(_ event: RemoteInputEvent) {
        guard let session else { return }
        switch event {
        case let .key(usage, down):
            guard let keysym = VNCKeysym(hidUsage: usage) else { return }
            session.key(keysym, down: down)
        case let .pointer(x, y):
            session.movePointer(to: CGPoint(x: Int(x), y: Int(y)))
        case let .button(button, down):
            switch button {
            case .left: session.press(.left, down: down)
            case .middle: session.press(.middle, down: down)
            case .right: session.press(.right, down: down)
            case .back, .forward: break
            }
        case let .scroll(dx, dy, precise):
            let lines = scroll.add(dx: dx, dy: dy, precise: precise)
            session.scroll(dx: lines.dx, dy: lines.dy)
        case let .text(text):
            session.type(text)
        }
    }
}

/// Scroll deltas (hundredths of a line, or of a point when precise) as the
/// whole lines the host posts, keeping the remainder.
nonisolated struct MacScreenScroll: Equatable {
    /// Hundredths per line: one wheel line, or about eight points of a trackpad swipe.
    static let hundredthsPerLine = 100.0
    static let hundredthsPerPreciseLine = 800.0
    private var remainder = (x: 0.0, y: 0.0)

    static func == (lhs: MacScreenScroll, rhs: MacScreenScroll) -> Bool { lhs.remainder == rhs.remainder }

    mutating func add(dx: Int32, dy: Int32, precise: Bool) -> (dx: Int, dy: Int) {
        let unit = precise ? Self.hundredthsPerPreciseLine : Self.hundredthsPerLine
        let x = remainder.x + Double(dx), y = remainder.y + Double(dy)
        let linesX = (x / unit).rounded(.towardZero), linesY = (y / unit).rounded(.towardZero)
        remainder = (x - linesX * unit, y - linesY * unit)
        return (Int(linesX), Int(linesY))
    }
}
