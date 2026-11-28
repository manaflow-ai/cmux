/// Turns a tap or a swipe in device points into paced ``PhoneTouch`` events
/// (`cmux-phone-core`'s ops `tap` and `swipe`).
struct PhoneGesture {
    /// The screen size in points the touches are normalized against.
    let screen: PhonePoint

    private struct Touch: Decodable {
        let phase: String
        let x: Double
        let y: Double
        let offsetMicros: Int64

        enum CodingKeys: String, CodingKey {
            case phase, x, y
            case offsetMicros = "offset_micros"
        }

        var touch: PhoneTouch {
            let phase: PhoneTouch.Phase = switch phase {
            case "began": .began
            case "moved": .moved
            default: .ended
            }
            return PhoneTouch(phase: phase, x: x, y: y, offset: .microseconds(offsetMicros))
        }
    }

    /// Down, then up 50 ms later (shorter reads as no touch to some UIKit controls).
    func tap(_ point: PhonePoint) throws -> [PhoneTouch] {
        try touches("tap", ["screen": [screen.x, screen.y], "point": [point.x, point.y]])
    }

    /// Down at `from`, one move per 16 ms frame, up at `to` after `seconds`.
    func swipe(from: PhonePoint, to: PhonePoint, seconds: Double) throws -> [PhoneTouch] {
        try touches("swipe", ["screen": [screen.x, screen.y], "from": [from.x, from.y], "to": [to.x, to.y], "seconds": seconds])
    }

    private func touches(_ op: String, _ fields: [String: Any]) throws -> [PhoneTouch] {
        do {
            return try PhoneRules.decode([Touch].self, "touches", op, fields, what: "the touches").map(\.touch)
        } catch {
            throw PhoneError.outsideScreen
        }
    }
}
