import Foundation

/// A brand that has a mark in design/agent-icons, such as `.claude` or `.openai`.
/// Codex and ChatGPT share `.openai`; `AgentBrandCatalog.brand(for:)` maps any agent,
/// harness or provider id to its brand.
public struct AgentBrandID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// A packed 0xRRGGBB color for the dark theme and one for the light theme.
public struct AgentBrandTone: Hashable, Sendable {
    public let dark: UInt32
    public let light: UInt32
    public init(dark: UInt32, light: UInt32) {
        self.dark = dark
        self.light = light
    }
    public func rgb(dark isDark: Bool) -> UInt32 { isDark ? dark : light }
}

public struct AgentBrandRect: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One path of a mark. `d` holds only absolute M, L, C and Z commands.
public struct AgentBrandPathSpec: Hashable, Sendable {
    public let d: String
    public let evenOdd: Bool
    /// This path's own brand color; nil uses the mark's tone.
    public let tone: AgentBrandTone?
    /// Opacity in the mono style; 0 hides detail that only the brand style paints.
    public let monoOpacity: Double
    /// Stroke at this width (view-box units) instead of filling.
    public let strokeWidth: Double?
    public init(d: String, evenOdd: Bool = false, tone: AgentBrandTone? = nil, monoOpacity: Double = 1, strokeWidth: Double? = nil) {
        self.d = d
        self.evenOdd = evenOdd
        self.tone = tone
        self.monoOpacity = monoOpacity
        self.strokeWidth = strokeWidth
    }
}

/// The brand style's rounded tile behind a mark (Kiro, Rovo Dev), in its own view box.
public struct AgentBrandTile: Hashable, Sendable {
    public let viewBox: AgentBrandRect
    public let radius: Double
    public let tone: AgentBrandTone
    public init(viewBox: AgentBrandRect, radius: Double, tone: AgentBrandTone) {
        self.viewBox = viewBox
        self.radius = radius
        self.tone = tone
    }
}

public struct AgentBrandGradientStop: Hashable, Sendable {
    public let offset: Double
    public let color: UInt32
    public let opacity: Double
    public init(offset: Double, color: UInt32, opacity: Double) {
        self.offset = offset
        self.color = color
        self.opacity = opacity
    }
}

/// A linear gradient the brand style lays over the whole mark (Gemini's highlights).
public struct AgentBrandGradient: Hashable, Sendable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double
    public let stops: [AgentBrandGradientStop]
    public init(x1: Double, y1: Double, x2: Double, y2: Double, stops: [AgentBrandGradientStop]) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.stops = stops
    }
}

/// A brand's mark: geometry in `viewBox`, the brand colors, and its optional tile and overlays.
public struct AgentBrandSpec: Hashable, Sendable {
    public let name: String
    /// The owner publishes only a wordmark (Amp), so the mark is wider than tall.
    public let isWordmark: Bool
    public let viewBox: AgentBrandRect
    public let tone: AgentBrandTone
    public let paths: [AgentBrandPathSpec]
    public let tile: AgentBrandTile?
    public let overlays: [AgentBrandGradient]
}

/// An agent or harness cmux supports.
public struct AgentDescriptor: Hashable, Sendable {
    public let id: String
    public let name: String
    /// nil when the agent publishes no mark; it draws the generic agent glyph.
    public let brand: AgentBrandID?
    public init(id: String, name: String, brand: AgentBrandID?) {
        self.id = id
        self.name = name
        self.brand = brand
    }
}

/// How a mark is painted.
public enum AgentBrandStyle: Hashable, Sendable {
    /// The owner's colors (and tile, if any), chosen for the surface's lightness.
    case brand
    /// One color for every path: a template image tinted by its surroundings.
    case mono
}

public struct AgentBrandCatalog {
    public init() {}
    /// The mark for a brand.
    public static func spec(for brand: AgentBrandID) -> AgentBrandSpec? { specs[brand] }

    /// The brand for an agent, harness, alias, binary path or provider id, or nil when it has no mark.
    ///
    /// Matching ignores case and surrounding space, then tries, in order: the whole id; the part after
    /// the last `:` (`acp:claude`); the last path component (`/usr/local/bin/codex`); the first word
    /// (`gemini cli`); the first `-`, `_` or `.` separated part (`codex-acp`). The first candidate the
    /// catalog knows decides, including ids known to have no mark (`prime-agent`).
    public static func brand(for agent: String?) -> AgentBrandID? {
        guard let agent else { return nil }
        for candidate in candidates(agent) {
            if let known = lookup[candidate] { return known }
        }
        return nil
    }

    /// The mark to draw for an agent id, or nil for the generic glyph.
    public static func spec(forAgent agent: String?) -> AgentBrandSpec? {
        brand(for: agent).flatMap { specs[$0] }
    }

    static func candidates(_ raw: String) -> [String] {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return [] }
        var out = [id]
        func add(_ value: Substring?) {
            guard let value, !value.isEmpty else { return }
            let candidate = String(value)
            if !out.contains(candidate) { out.append(candidate) }
        }
        add(id.split(separator: ":").last)
        add(id.split(separator: "/").last)
        let word = out.last.flatMap { $0.split(whereSeparator: { $0.isWhitespace }).first }
        add(word)
        add(word.flatMap { $0.split(whereSeparator: { "-_.".contains($0) }).first })
        return out
    }
}
