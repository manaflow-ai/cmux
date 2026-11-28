public import Foundation

/// One agent's dot signature (`appearance.agentSignature`): the glyph acpmux makes from a session id
/// (`session/signature`, cmux-wallpaper `signature.rs` `Glyph`, built on the particles wallpaper's
/// manifest). A pure function of the id, so a client keeps it forever once read
/// (``SidebarAgentSignatures``). Every number is a fraction of the glyph's square box.
public nonisolated struct SidebarAgentSignature: Hashable, Sendable {
    /// One dot: its center (`x` from the left, `y` from the top, 0...1 of the box), its radius as a
    /// fraction of the box, and its phase (0...1) for the running line's drift.
    public struct Dot: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var r: Double
        public var phase: Double

        public init(x: Double, y: Double, r: Double, phase: Double) {
            (self.x, self.y, self.r, self.phase) = (x, y, r, phase)
        }
    }

    /// The id's seed, 0...1.
    public var seed: Double
    /// The particles variant's name ("Dust").
    public var variant: String
    /// The variant's accent, `#RRGGBB`.
    public var accent: String
    /// How far the running line's dots drift (the variant's `speed`); the sidebar's glyph is static.
    public var drift: Double
    public var dots: [Dot]

    public init(seed: Double, variant: String, accent: String, drift: Double, dots: [Dot]) {
        self.seed = seed
        self.variant = variant
        self.accent = accent
        self.drift = drift
        self.dots = dots
    }

    /// The most ids one `session/signature` request carries (acpmux refuses more).
    public static let batchLimit = 512

    /// The accent's channels, 0...1; nil when it is not `#RRGGBB`.
    public var accentRGB: (red: Double, green: Double, blue: Double)? {
        let hex = accent.hasPrefix("#") ? accent.dropFirst() : Substring(accent)
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// A glyph from its JSON object; nil when the accent or the dots are missing.
    public init?(json: [String: Any]) {
        func number(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        guard let accent = json["accent"] as? String, let dots = json["dots"] as? [Any] else { return nil }
        let parsed = dots.compactMap { item -> Dot? in
            guard let dot = item as? [String: Any], let x = number(dot["x"]), let y = number(dot["y"]),
                  let r = number(dot["r"]) else { return nil }
            return Dot(x: x, y: y, r: r, phase: number(dot["phase"]) ?? 0)
        }
        self.init(seed: number(json["seed"]) ?? 0, variant: json["variant"] as? String ?? "", accent: accent,
                  drift: number(json["drift"]) ?? 1, dots: parsed)
    }

    /// The `session/signature` request line for `ids` (at most ``batchLimit``), newline-ended.
    public static func request(_ ids: [String], id: Int = 1) -> Data {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "session/signature",
                                      "params": ["sessionIds": Array(ids.prefix(batchLimit))]]
        var line = (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data()
        line.append(0x0A)
        return line
    }

    /// The glyphs of a `session/signature` reply line, by session id; nil for an error, or a reply
    /// that is not one.
    public static func signatures(reply: Data) -> [String: SidebarAgentSignature]? {
        guard let message = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any], message["error"] == nil,
              let result = message["result"] as? [String: Any], let signatures = result["signatures"] as? [String: Any]
        else { return nil }
        var glyphs: [String: SidebarAgentSignature] = [:]
        for (id, value) in signatures {
            if let json = value as? [String: Any], let glyph = SidebarAgentSignature(json: json) { glyphs[id] = glyph }
        }
        return glyphs
    }
}
