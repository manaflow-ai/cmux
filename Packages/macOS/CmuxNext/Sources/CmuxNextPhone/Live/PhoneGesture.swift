/// Turns a tap or a swipe in device points into paced ``PhoneTouch`` events.
struct PhoneGesture {
    static let shortestSwipe = 0.05
    static let defaultSwipe = 0.3
    /// The screen size in points the touches are normalized against.
    let screen: PhonePoint

    /// Normalizes `point`; nil when it is outside the screen.
    func normalized(_ point: PhonePoint) -> (x: Double, y: Double)? {
        guard screen.x > 0, screen.y > 0 else { return nil }
        let x = point.x / screen.x, y = point.y / screen.y
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (x, y)
    }

    /// Down, then up 50 ms later (shorter reads as no touch to some UIKit controls).
    func tap(_ point: PhonePoint) throws -> [PhoneTouch] {
        guard let at = normalized(point) else { throw PhoneError.outsideScreen }
        return [PhoneTouch(phase: .began, x: at.x, y: at.y, offset: .zero),
                PhoneTouch(phase: .ended, x: at.x, y: at.y, offset: .milliseconds(50))]
    }

    /// Down at `from`, one move per 16 ms frame, up at `to` after `seconds`.
    func swipe(from: PhonePoint, to: PhonePoint, seconds: Double) throws -> [PhoneTouch] {
        guard let start = normalized(from), let end = normalized(to) else { throw PhoneError.outsideScreen }
        // A gesture's length (input timing the caller chose), not an animation.
        let duration = max(Self.shortestSwipe, seconds.isFinite ? seconds : Self.defaultSwipe)
        guard duration <= PhoneInput.longestSwipe else { throw PhoneError.outOfRange(what: "the swipe's seconds") }
        let steps = try max(2, Self.whole(duration / 0.016))
        var touches = [PhoneTouch(phase: .began, x: start.x, y: start.y, offset: .zero)]
        for step in 1..<steps {
            let t = Double(step) / Double(steps)
            let offset = try Self.whole(duration * 1_000_000 * t)
            touches.append(PhoneTouch(phase: .moved, x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t,
                                      offset: .microseconds(offset)))
        }
        let total = try Self.whole((duration * 1000).rounded())
        touches.append(PhoneTouch(phase: .ended, x: end.x, y: end.y, offset: .milliseconds(total)))
        return touches
    }

    /// `value` without its fraction; a typed error, not a trap, when no `Int` holds it.
    private static func whole(_ value: Double) throws -> Int {
        guard let whole = Int(exactly: value.rounded(.towardZero)) else { throw PhoneError.outOfRange(what: "the swipe's seconds") }
        return whole
    }
}
