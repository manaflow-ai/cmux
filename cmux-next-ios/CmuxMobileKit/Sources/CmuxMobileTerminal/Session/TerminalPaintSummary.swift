import Foundation

/// hostd's join of one paint report, sent back on the same `phone-frames` channel
/// (`{"kind":"paint-summary",...}`): Mac redraw to iPhone paint on the Mac's clock, with the
/// clock offset's error bound. hostd computes it (Rust, `paint_latency::summarize`); the phone
/// only reads it for the DEBUG overlay.
public struct TerminalPaintSummary: Sendable, Equatable {
    /// p50/p95/max of one part, ms.
    public struct Part: Sendable, Equatable {
        public var n: Int
        public var p50: Double
        public var p95: Double
        public var max: Double

        public init(n: Int, p50: Double, p95: Double, max: Double) {
            self.n = n
            self.p50 = p50
            self.p95 = p95
            self.max = max
        }
    }

    /// The newest sample's Mac redraw to phone paint.
    public var lastTotalMs: Double?
    public var total: Part?
    public var mac: Part?
    public var wire: Part?
    public var phonePaint: Part?
    /// Phone clock minus Mac clock, and the most it can be wrong by (half the probe's round trip).
    public var offsetMs: Double?
    public var offsetErrorMs: Double?

    public init(lastTotalMs: Double? = nil, total: Part? = nil, mac: Part? = nil, wire: Part? = nil,
                phonePaint: Part? = nil, offsetMs: Double? = nil, offsetErrorMs: Double? = nil) {
        self.lastTotalMs = lastTotalMs
        self.total = total
        self.mac = mac
        self.wire = wire
        self.phonePaint = phonePaint
        self.offsetMs = offsetMs
        self.offsetErrorMs = offsetErrorMs
    }

    /// The summary in hostd's answer to a paint report; nil for anything else.
    public init?(answer: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              object["kind"] as? String == "paint-summary" else { return nil }
        func number(_ key: String, in object: [String: Any]) -> Double? {
            (object[key] as? NSNumber)?.doubleValue
        }
        func part(_ key: String) -> Part? {
            guard let part = object[key] as? [String: Any],
                  let n = number("n", in: part), let p50 = number("p50_ms", in: part),
                  let p95 = number("p95_ms", in: part), let max = number("max_ms", in: part) else { return nil }
            return Part(n: Int(n), p50: p50, p95: p95, max: max)
        }
        self.init(lastTotalMs: number("last_total_ms", in: object), total: part("total"), mac: part("mac"),
                  wire: part("wire"), phonePaint: part("phone_paint"), offsetMs: number("offset_ms", in: object),
                  offsetErrorMs: number("offset_error_ms", in: object))
    }

    /// The overlay's two lines: symbols, fixed width, so it never shifts the layout.
    /// Line 1: `Δ` the newest redraw-to-paint, then p50/p95 over the last report, `±` the clock error.
    /// Line 2: each hop's p95, so the dominant one is a number: `mac` Mac redraw to socket write,
    /// `net` socket write to phone receive, `app` phone receive to the present that showed it.
    public var overlayText: String {
        func ms(_ value: Double?) -> String {
            guard let value else { return "  –" }
            return String(format: "%3.0f", value.rounded())
        }
        let error = offsetErrorMs.map { String(format: "±%.1f", $0) } ?? "±?"
        return "Δ\(ms(lastTotalMs)) p50\(ms(total?.p50)) p95\(ms(total?.p95)) \(error)\n"
            + "mac\(ms(mac?.p95)) net\(ms(wire?.p95)) app\(ms(phonePaint?.p95))"
    }

    /// Posted by a session with the summary of its last paint report; the object is the session
    /// (``TerminalSession/underlyingSession``), `userInfo["summary"]` the summary.
    public static let didArrive = Notification.Name("cmuxMobile.terminal.paintSummary")
}

/// The DEBUG paint-latency overlay: Mac redraw to iPhone paint on the terminal, live.
/// Off by default; Settings → Transport → Developer, or `-cmuxMobile.dev.paintLatencyOverlay YES`.
/// Release builds never read it.
public enum TerminalPaintOverlay {
    /// The same key as `DeveloperOptions.paintLatencyOverlayKey` (this package can't import it).
    public static let key = "cmuxMobile.dev.paintLatencyOverlay"
    /// How often the phone reports while the overlay is on (the default is every 5 s).
    public static let reportEveryMs: Double = 1000

    public static var enabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: key)
        #else
        false
        #endif
    }
}
