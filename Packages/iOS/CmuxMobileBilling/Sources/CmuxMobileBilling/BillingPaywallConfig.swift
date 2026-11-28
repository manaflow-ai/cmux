import Foundation

/// How the paywall presents the plans on sale.
public enum BillingPaywallLayout: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// One card per plan, the highlighted plan marked as recommended.
    case cards
    /// A Free, Pro and Max feature table above compact plan rows.
    case comparison
    /// One large card for the highlighted plan; the others sit behind
    /// "See all plans".
    case focus
    /// A Free and Pro check table and one purchase button; "See Max" opens
    /// ``planTabs`` on Max.
    case checklist
    /// Pro and Max tabs with each plan's benefits and its billing periods
    /// as two large cards.
    case planTabs
    /// A dark header with cmux art, four benefit rows, and a Pro and Max
    /// selector by the button.
    case hero
    /// A trial timeline (today, the reminder, the first charge). Shown only
    /// with a granted free trial; otherwise the paywall shows ``cards``.
    case trialTimeline
    /// An inset list of plans by compute specs, each row with its price and
    /// its own Subscribe button.
    case specList
}

/// What the purchase button says.
public enum BillingPaywallCTAStyle: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// The StoreKit price and period, such as "Subscribe for $74.99/month".
    case price
    /// An action with the plan name, such as "Continue with Pro".
    case action
}

/// Where the paywall configuration of the current session came from.
public enum BillingPaywallConfigSource: String, Sendable, Equatable, Hashable {
    /// The server sent a valid `paywall` object.
    case server
    /// The server sent none or an invalid one; the app uses
    /// ``BillingPaywallConfig/control``.
    case builtIn = "built_in"
}

/// The server-driven paywall presentation: the `paywall` object of the
/// account-token response.
///
/// The server assigns the experiment variant. The configuration chooses only
/// copy and presentation. Prices, periods and product ids always come from
/// StoreKit and the server's product list, never from this object, and every
/// string is plain text.
///
/// Decoding is strict: an unknown layout, a string over its length limit, more
/// than five bullets, or a highlighted plan other than `pro` or `max` makes
/// the whole object invalid, and the app falls back to ``control``.
///
/// ```json
/// {"experiment":"ios-paywall-v1","variant":"control","layout":"cards",
///  "headline":"…","subheadline":"…","bullets":["…"],
///  "highlightedPlanId":"pro","defaultBillingPeriod":"yearly",
///  "ctaStyle":"price","showYearlySavings":true}
/// ```
public struct BillingPaywallConfig: Sendable, Equatable, Hashable, Codable {
    /// The experiment key, such as `ios-paywall-v1`.
    public let experiment: String
    /// The assigned variant, such as `control`.
    public let variant: String
    /// The plan presentation.
    public let layout: BillingPaywallLayout
    /// The title, at most ``headlineLimit`` characters.
    public let headline: String
    /// The sentence under the title, at most ``subheadlineLimit`` characters;
    /// empty hides it.
    public let subheadline: String
    /// Up to ``bulletCountLimit`` selling points, each at most
    /// ``bulletLimit`` characters.
    public let bullets: [String]
    /// The plan shown as recommended: `pro`, `max`, or nil for none.
    public let highlightedPlanID: BillingPlanID?
    /// The billing period selected first.
    public let defaultBillingPeriod: BillingPeriod
    /// What the purchase button says.
    public let ctaStyle: BillingPaywallCTAStyle
    /// Whether the yearly savings computed from StoreKit prices is shown.
    public let showYearlySavings: Bool
    /// Headlines for specific entry points, keyed by `entry_point` value,
    /// such as `locked_vm_size`. An entry point without one uses
    /// ``headline``. Entries over ``headlineLimit`` are dropped.
    public let entryPointHeadlines: [String: String]
    /// For ``BillingPaywallLayout/specList``: spec lines per plan id from the
    /// server's pricing facts, such as `["20 vCPUs · 40 GB RAM", ...]`. Up to
    /// four plain lines of at most 80 characters; bad entries are dropped.
    public let planSpecs: [String: [String]]

    /// Maximum headline length in characters.
    public static let headlineLimit = 60
    /// Maximum subheadline length in characters.
    public static let subheadlineLimit = 140
    /// Maximum bullet length in characters.
    public static let bulletLimit = 80
    /// Maximum number of bullets.
    public static let bulletCountLimit = 5

    /// Creates a configuration. Returns nil when a value is outside the
    /// schema's limits.
    public init?(
        experiment: String,
        variant: String,
        layout: BillingPaywallLayout,
        headline: String,
        subheadline: String,
        bullets: [String],
        highlightedPlanID: BillingPlanID?,
        defaultBillingPeriod: BillingPeriod,
        ctaStyle: BillingPaywallCTAStyle,
        showYearlySavings: Bool,
        entryPointHeadlines: [String: String] = [:],
        planSpecs: [String: [String]] = [:]
    ) {
        let headline = Self.plain(headline)
        let subheadline = Self.plain(subheadline)
        let bullets = bullets.map(Self.plain)
        let experiment = experiment.trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !experiment.isEmpty, experiment.count <= 64,
              !variant.isEmpty, variant.count <= 64,
              !headline.isEmpty, headline.count <= Self.headlineLimit,
              subheadline.count <= Self.subheadlineLimit,
              bullets.count <= Self.bulletCountLimit,
              bullets.allSatisfy({ !$0.isEmpty && $0.count <= Self.bulletLimit })
        else { return nil }
        if let highlightedPlanID, highlightedPlanID != .pro, highlightedPlanID != .max { return nil }
        self.experiment = experiment
        self.variant = variant
        self.layout = layout
        self.headline = headline
        self.subheadline = subheadline
        self.bullets = bullets
        self.highlightedPlanID = highlightedPlanID
        self.defaultBillingPeriod = defaultBillingPeriod
        self.ctaStyle = ctaStyle
        self.showYearlySavings = showYearlySavings
        self.entryPointHeadlines = entryPointHeadlines.reduce(into: [:]) { result, entry in
            let text = Self.plain(entry.value)
            if !text.isEmpty, text.count <= Self.headlineLimit { result[entry.key] = text }
        }
        self.planSpecs = planSpecs.reduce(into: [:]) { result, entry in
            let lines = entry.value.prefix(4).map(Self.plain).filter { !$0.isEmpty && $0.count <= Self.bulletLimit }
            if !lines.isEmpty { result[entry.key] = Array(lines) }
        }
    }

    /// The headline for `entryPoint`: its own when the server sent one,
    /// else ``headline``.
    public func headline(for entryPoint: BillingEntryPoint) -> String {
        entryPointHeadlines[entryPoint.rawValue] ?? headline
    }

    /// The built-in configuration, equal to the server's `control` variant.
    /// Used when the server sends no `paywall` object or an invalid one.
    public static let control = BillingPaywallConfig(
        experiment: "ios-paywall-v1",
        variant: "control",
        layout: .cards,
        headline: "Upgrade to cmux Cloud",
        subheadline: "Run coding agents on fast cloud machines and reach them from your iPhone and your Mac.",
        bullets: [],
        highlightedPlanID: .pro,
        defaultBillingPeriod: .monthly,
        ctaStyle: .price,
        showYearlySavings: true
    )!

    enum CodingKeys: String, CodingKey {
        case experiment
        case variant
        case layout
        case headline
        case subheadline
        case bullets
        case highlightedPlanID = "highlightedPlanId"
        case defaultBillingPeriod
        case ctaStyle
        case showYearlySavings
        case entryPointHeadlines
        case planSpecs
    }

    /// Decodes the schema exactly; any violation throws, so the caller falls
    /// back to ``control``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let highlighted = try container.decodeIfPresent(String.self, forKey: .highlightedPlanID)
        guard let config = BillingPaywallConfig(
            experiment: try container.decode(String.self, forKey: .experiment),
            variant: try container.decode(String.self, forKey: .variant),
            layout: try container.decode(BillingPaywallLayout.self, forKey: .layout),
            headline: try container.decode(String.self, forKey: .headline),
            subheadline: try container.decode(String.self, forKey: .subheadline),
            bullets: try container.decode([String].self, forKey: .bullets),
            highlightedPlanID: highlighted.map { BillingPlanID(rawValue: $0) },
            defaultBillingPeriod: try container.decode(BillingPeriod.self, forKey: .defaultBillingPeriod),
            ctaStyle: try container.decode(BillingPaywallCTAStyle.self, forKey: .ctaStyle),
            showYearlySavings: try container.decode(Bool.self, forKey: .showYearlySavings),
            // Optional and lenient: a bad map drops the map, not the config.
            entryPointHeadlines: (try? container.decodeIfPresent([String: String].self, forKey: .entryPointHeadlines)) ?? [:],
            planSpecs: (try? container.decodeIfPresent([String: [String]].self, forKey: .planSpecs)) ?? [:]
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "paywall config is outside the schema limits"
            ))
        }
        self = config
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(experiment, forKey: .experiment)
        try container.encode(variant, forKey: .variant)
        try container.encode(layout, forKey: .layout)
        try container.encode(headline, forKey: .headline)
        try container.encode(subheadline, forKey: .subheadline)
        try container.encode(bullets, forKey: .bullets)
        try container.encode(highlightedPlanID?.rawValue, forKey: .highlightedPlanID)
        try container.encode(defaultBillingPeriod, forKey: .defaultBillingPeriod)
        try container.encode(ctaStyle, forKey: .ctaStyle)
        try container.encode(showYearlySavings, forKey: .showYearlySavings)
        if !entryPointHeadlines.isEmpty {
            try container.encode(entryPointHeadlines, forKey: .entryPointHeadlines)
        }
        if !planSpecs.isEmpty {
            try container.encode(planSpecs, forKey: .planSpecs)
        }
    }

    /// Plain single-line text: control characters (including line breaks)
    /// become spaces and the ends are trimmed.
    private static func plain(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
