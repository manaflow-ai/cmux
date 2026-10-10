import Foundation

/// The color of one agent session's cursor: the ten named palettes of
/// cursor-overlay (`Palette::for_instance`, a port of AgentCursorPalette.cs).
/// The cursor, the lease badge and the activity rows all take a session's
/// color from here, so they always match the cmux-cua renderer.
public struct AgentCursorPalette: Sendable, Equatable {
    /// RGBA, 0...255.
    public typealias RGBA = [UInt8]

    public var name: String
    public var cursorStart: RGBA
    public var cursorMid: RGBA
    public var cursorEnd: RGBA
    public var bloomOuter: RGBA
    public var bloomInner: RGBA

    /// The palette for a session id (the agent cursor key).
    public static func forSession(_ sessionID: String) -> AgentCursorPalette {
        if sessionID.isEmpty || sessionID == "default" {
            return all[0]
        }
        if let named = all.first(where: { $0.name == sessionID }) {
            return named
        }
        let alternates = Array(all.dropFirst())
        return alternates[stableIndex(sessionID, count: alternates.count)]
    }

    /// Lerp along start -> mid -> end at `t` in 0...1 (mid at 0.53).
    public func gradient(at t: Double) -> RGBA {
        let t = min(max(t, 0), 1)
        if t <= 0.53 {
            return Self.lerp(cursorStart, cursorMid, t / 0.53)
        }
        return Self.lerp(cursorMid, cursorEnd, (t - 0.53) / 0.47)
    }

    private static func lerp(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        var out: RGBA = []
        for i in 0..<3 {
            let from = Double(a[i])
            let to = Double(b[i])
            let value: Double = from + (to - from) * t
            out.append(UInt8(value.rounded(.toNearestOrAwayFromZero)))
        }
        out.append(255)
        return out
    }

    /// Rust `stable_index`: a numeric suffix n > 0 picks n-1, a one-letter
    /// ASCII suffix picks its alphabet position, otherwise FNV-1a over the
    /// id's Unicode scalars, all modulo `count`.
    private static func stableIndex(_ id: String, count: Int) -> Int {
        let separators: Set<Character> = ["-", "_", "."]
        let suffix = id.lastIndex(where: { separators.contains($0) }).map { String(id[id.index(after: $0)...]) } ?? id
        if let n = UInt(suffix, radix: 10), n > 0 {
            return Int((n - 1) % UInt(count))
        }
        if suffix.unicodeScalars.count == 1, let scalar = suffix.unicodeScalars.first,
           scalar.isASCII, CharacterSet.letters.contains(scalar) {
            let lower = Character(scalar).lowercased().unicodeScalars.first!.value
            return Int(lower - 97) % count
        }
        var hash: UInt32 = 2_166_136_261
        for scalar in id.unicodeScalars {
            hash ^= scalar.value
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }

    private static func rgba(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGBA { [r, g, b, 255] }

    /// cursor-overlay PALETTE_DATA, same order (index 0 is the default).
    public static let all: [AgentCursorPalette] = [
        .init(name: "default_blue", cursorStart: rgba(219, 238, 255), cursorMid: rgba(94, 192, 232), cursorEnd: rgba(84, 205, 160), bloomOuter: rgba(188, 232, 252), bloomInner: rgba(238, 248, 255)),
        .init(name: "soft_purple", cursorStart: rgba(238, 226, 255), cursorMid: rgba(178, 132, 255), cursorEnd: rgba(118, 194, 255), bloomOuter: rgba(214, 188, 255), bloomInner: rgba(246, 238, 255)),
        .init(name: "rose_gold", cursorStart: rgba(255, 231, 238), cursorMid: rgba(247, 132, 170), cursorEnd: rgba(255, 181, 108), bloomOuter: rgba(255, 190, 211), bloomInner: rgba(255, 243, 232)),
        .init(name: "mint_lime", cursorStart: rgba(226, 255, 240), cursorMid: rgba(96, 218, 174), cursorEnd: rgba(178, 229, 72), bloomOuter: rgba(178, 245, 217), bloomInner: rgba(241, 255, 231)),
        .init(name: "amber", cursorStart: rgba(255, 244, 214), cursorMid: rgba(244, 178, 66), cursorEnd: rgba(255, 126, 92), bloomOuter: rgba(255, 219, 140), bloomInner: rgba(255, 248, 225)),
        .init(name: "aqua", cursorStart: rgba(221, 252, 255), cursorMid: rgba(76, 204, 224), cursorEnd: rgba(63, 222, 166), bloomOuter: rgba(172, 241, 249), bloomInner: rgba(236, 255, 251)),
        .init(name: "orchid", cursorStart: rgba(252, 228, 255), cursorMid: rgba(221, 113, 236), cursorEnd: rgba(255, 139, 196), bloomOuter: rgba(237, 181, 246), bloomInner: rgba(255, 239, 252)),
        .init(name: "crimson", cursorStart: rgba(255, 226, 226), cursorMid: rgba(232, 82, 98), cursorEnd: rgba(150, 94, 255), bloomOuter: rgba(255, 168, 178), bloomInner: rgba(255, 240, 241)),
        .init(name: "chartreuse", cursorStart: rgba(247, 255, 218), cursorMid: rgba(184, 220, 54), cursorEnd: rgba(72, 190, 119), bloomOuter: rgba(224, 247, 128), bloomInner: rgba(249, 255, 232)),
        .init(name: "cobalt", cursorStart: rgba(226, 235, 255), cursorMid: rgba(80, 126, 236), cursorEnd: rgba(91, 219, 222), bloomOuter: rgba(170, 195, 255), bloomInner: rgba(239, 246, 255)),
    ]
}
