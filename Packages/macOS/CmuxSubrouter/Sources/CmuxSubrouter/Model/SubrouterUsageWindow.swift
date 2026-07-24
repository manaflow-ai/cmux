/// One rate-limit window reported by `GET /_subrouter/usage-status`.
///
/// **Wire format warning.** The daemon's Go struct has no JSON tags, so the
/// keys are the raw PascalCase Go field names (`Name`, `UsedPercent`, …) —
/// unlike every other subrouter payload, which uses snake_case. The explicit
/// `CodingKeys` here are load-bearing; never decode this type with a global
/// key-conversion strategy.
///
/// Codex windows carry `LimitWindowSeconds`; Claude windows leave it `0` and
/// are classified by name (`"5h"`, `"7d"`, `"opus-weekly"`, …).
public struct SubrouterUsageWindow: Sendable, Hashable, Codable {
    /// The daemon's window name (e.g. `"primary"`, `"secondary"`, `"5h"`,
    /// `"7d"`, `"opus-weekly"`, or `"<Feature>/primary"`).
    public var name: String
    /// Percent of the window's quota consumed. May exceed `[0, 100]` on the
    /// wire; use ``clampedUsedPercent`` for display and threshold logic.
    public var usedPercent: Double
    /// The window length in seconds, or `0` when the daemon derived the
    /// window from a named reset (Claude windows).
    public var limitWindowSeconds: Int64
    /// Seconds until the window resets, or `0`/negative when unknown or due.
    public var resetAfterSeconds: Int64
    /// The per-feature limit name for feature-scoped windows, else empty.
    public var feature: String

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case usedPercent = "UsedPercent"
        case limitWindowSeconds = "LimitWindowSeconds"
        case resetAfterSeconds = "ResetAfterSeconds"
        case feature = "Feature"
    }

    /// Creates a usage window.
    /// - Parameters:
    ///   - name: The daemon's window name.
    ///   - usedPercent: Percent of quota consumed.
    ///   - limitWindowSeconds: Window length in seconds, `0` when unknown.
    ///   - resetAfterSeconds: Seconds until reset, `0` when unknown.
    ///   - feature: Per-feature limit name, empty when provider-wide.
    public init(
        name: String,
        usedPercent: Double,
        limitWindowSeconds: Int64 = 0,
        resetAfterSeconds: Int64 = 0,
        feature: String = ""
    ) {
        self.name = name
        self.usedPercent = usedPercent
        self.limitWindowSeconds = limitWindowSeconds
        self.resetAfterSeconds = resetAfterSeconds
        self.feature = feature
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent) ?? 0
        self.limitWindowSeconds = try container.decodeIfPresent(Int64.self, forKey: .limitWindowSeconds) ?? 0
        self.resetAfterSeconds = try container.decodeIfPresent(Int64.self, forKey: .resetAfterSeconds) ?? 0
        self.feature = try container.decodeIfPresent(String.self, forKey: .feature) ?? ""
    }
}

extension SubrouterUsageWindow {
    /// Seconds at or below which a window with a known length counts as a
    /// short (session) quota window: 6 hours, mirroring `sr.go`.
    public static let shortQuotaMaxSeconds: Int64 = 6 * 60 * 60
    /// Seconds at or above which a window with a known length counts as a
    /// long (weekly) quota window: 6 days, mirroring `sr.go`.
    public static let longQuotaMinSeconds: Int64 = 6 * 24 * 60 * 60
    /// The used-percent threshold at or above which a window is treated as
    /// nearly exhausted (the `sr` red threshold).
    public static let nearlyExhaustedPercent: Double = 90

    /// ``usedPercent`` clamped to `[0, 100]`, mirroring `sr.go`'s
    /// `clampUsagePercent`.
    public var clampedUsedPercent: Double {
        min(max(usedPercent, 0), 100)
    }

    /// Whether this is a short (~5h session) quota window, mirroring
    /// `sr.go`'s `isShortQuotaWindow`: by length when known, else by the name
    /// containing `"5h"` or `"primary"`.
    public var isShortQuotaWindow: Bool {
        if limitWindowSeconds > 0 {
            return limitWindowSeconds <= Self.shortQuotaMaxSeconds
        }
        let lowered = name.lowercased()
        return lowered.contains("5h") || lowered.contains("primary")
    }

    /// Whether this is a long (weekly) quota window, mirroring `sr.go`'s
    /// `isLongQuotaWindow`: by length when known, else by the name containing
    /// `"7d"` or `"weekly"`.
    public var isLongQuotaWindow: Bool {
        if limitWindowSeconds > 0 {
            return limitWindowSeconds >= Self.longQuotaMinSeconds
        }
        let lowered = name.lowercased()
        return lowered.contains("7d") || lowered.contains("weekly")
    }

    /// Whether the window is fully consumed (clamped usage at 100%).
    public var isFullyConsumed: Bool {
        clampedUsedPercent >= 100
    }

    /// Whether the window is at or past ``nearlyExhaustedPercent``.
    public var isNearlyExhausted: Bool {
        clampedUsedPercent >= Self.nearlyExhaustedPercent
    }

    /// `sr.go`'s `isModelScopedWindow`: the window limits one model/feature
    /// pool (nonempty `Feature`), so its saturation does not make the whole
    /// account unusable.
    public var isModelScoped: Bool {
        !feature.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
