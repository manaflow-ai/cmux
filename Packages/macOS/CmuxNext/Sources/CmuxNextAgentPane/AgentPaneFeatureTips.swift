public import Foundation
import CmuxNextSettings

/// The app's feature tip records (`tips.state`; leo-workspace design/feature-tips.md), kept for the
/// life of the install. Leo, 2026-10-30: "no this should be very very infrequent like app
/// installation level frequent and if they havent used the browser".
///
/// - Each tip shows at most once per install: ``claim(_:feature:)`` records it `shown`, and a tip
///   with any record never shows again (`closed` with its X, `used` its feature).
/// - At most one tip every ``minimumDaysBetweenTips`` days, across every tip, the sidebar's
///   "Did you know?" card included (one shared record, `FeatureTipBudget`).
/// - A tip about a feature the person already used never shows: the app notes each use
///   (``noteFeatureUsed(_:)``; the browser from `TabContentCache`, where every browser tab gets its
///   page), and an install that existed before tips (``settleInstall(launchedBefore:)``) counts as
///   having used the browser.
///
/// An agent page's own storage ends with the launch and pages share none, so the app keeps all of
/// it, on this Mac, in its defaults (client view state, as ``AgentPaneLastPicks``; never cmux.json
/// and never the daemon). The page decides when a moment is right
/// (webviews/src/ui/featureTips/policy.ts); the app decides whether this install may see a tip.
///
/// ```swift
/// AgentPaneFeatureTipRecords().noteFeatureUsed(AgentPaneFeatureTipRecords.browserFeature)
/// ```
public final class AgentPaneFeatureTipRecords {
    /// The browser, the feature of the Browser button's tip.
    public static let browserFeature = "browser"
    /// The fewest days between two tips, whichever they are (``FeatureTipBudget``).
    public static let minimumDaysBetweenTips = FeatureTipBudget.minimumDaysBetweenTips
    /// The most tips kept; a highlight gets a tip rarely, so this bounds a misbehaving page only.
    static let maxRecords = 256
    static let recordsKey = "agentPane.featureTips"
    static let usedKey = "agentPane.featureTips.usedFeatures"

    private let defaults: UserDefaults
    private let now: () -> Date

    /// Records kept in `defaults` (a test's own suite), dated by `now`.
    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// Every record by tip id: `shown`, `closed` or `used`.
    public var records: [String: String] {
        (defaults.dictionary(forKey: Self.recordsKey) ?? [:]).compactMapValues { $0 as? String }
    }

    /// The features this install has used, sorted.
    public var usedFeatures: [String] {
        (defaults.stringArray(forKey: Self.usedKey) ?? []).sorted()
    }

    /// Keeps `closed` or `used` for tip `id`. Both are final.
    ///
    /// - Returns: Every record after the write.
    @discardableResult
    public func keep(_ id: String, _ state: String) -> [String: String] {
        var all = records
        if all[id] == "closed" || all[id] == "used" { return all }
        if all[id] == nil, all.count >= Self.maxRecords { return all }
        all[id] = state
        defaults.set(all, forKey: Self.recordsKey)
        return all
    }

    /// The person used `feature` (opened a browser tab, by any path): its tip never shows.
    /// Idempotent; it writes only the first time.
    public func noteFeatureUsed(_ feature: String) {
        var used = defaults.stringArray(forKey: Self.usedKey) ?? []
        guard !used.contains(feature) else { return }
        used.append(feature)
        defaults.set(used, forKey: Self.usedKey)
    }

    /// Decides, once per install, whether this install existed before tips did. `launchedBefore`
    /// says whether the app ran here before this launch (the What's New record, read before this
    /// launch writes it). An existing install counts as having used the browser: nothing records
    /// its past browser use reliably (agent tabs, private tabs and cleared history leave no trace),
    /// and a person who has run cmux has long seen the Browser button. Only a fresh install can see
    /// the Browser tip.
    public func settleInstall(launchedBefore: Bool) {
        guard FeatureTipBudget(defaults: defaults).settleInstall(launchedBefore: launchedBefore) else { return }
        if launchedBefore { noteFeatureUsed(Self.browserFeature) }
    }

    /// Takes tip `id` about `feature` for this install: true only when the tip never showed, its
    /// feature was never used, and no tip showed in the last ``minimumDaysBetweenTips`` days. A
    /// true answer records it `shown`, so it never shows again, whichever page or window asks.
    public func claim(_ id: String, feature: String?) -> Bool {
        if records[id] != nil { return false }
        if let feature, usedFeatures.contains(feature) { return false }
        let today = now()
        let budget = FeatureTipBudget(defaults: defaults)
        guard budget.isOpen(at: today) else { return false }
        var all = records
        guard all.count < Self.maxRecords else { return false }
        all[id] = "shown"
        defaults.set(all, forKey: Self.recordsKey)
        budget.spend(at: today)
        return true
    }

    /// Whether a page may name `id` (a highlight id or a feature: lower-case letters, digits and
    /// dashes) and keep `state` (`closed` or `used`).
    public nonisolated static func accepts(id: String, state: String) -> Bool {
        isName(id) && (state == "closed" || state == "used")
    }

    nonisolated static func isName(_ name: String) -> Bool {
        let characters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return (1...80).contains(name.utf8.count) && name.unicodeScalars.allSatisfy(characters.contains)
    }
}

extension AgentPaneModel {
    /// `tips.state {}` reads the records and `tips.state {id, state}` keeps one, both answering
    /// `{states, used}`; `tips.state {claim, feature?}` asks to show a tip, answering `{claimed}`. A
    /// page on an app without this op shows no tip, since none could stay closed.
    func featureTipState(_ request: AgentPaneFeatureTipRequest) -> [String: Any] {
        let records = featureTipRecords
        switch request {
        case .read:
            return AgentPaneReply.success(["states": records.records, "used": records.usedFeatures])
        case .keep(let id, let state):
            return AgentPaneReply.success(["states": records.keep(id, state), "used": records.usedFeatures])
        case .claim(let id, let feature):
            return AgentPaneReply.success(["claimed": records.claim(id, feature: feature)])
        }
    }
}

/// What a page asks of `tips.state`.
public nonisolated enum AgentPaneFeatureTipRequest: Equatable, Sendable {
    case read
    case keep(id: String, state: String)
    case claim(id: String, feature: String?)

    /// The request `params` make, or nil for params a page may not send.
    public init?(_ params: [String: Any]?) {
        let params = params ?? [:]
        let keys = Set(params.keys)
        if keys.isEmpty {
            self = .read
        } else if keys == ["id", "state"], let id = params["id"] as? String, let state = params["state"] as? String,
                  AgentPaneFeatureTipRecords.accepts(id: id, state: state) {
            self = .keep(id: id, state: state)
        } else if keys.isSubset(of: ["claim", "feature"]), let id = params["claim"] as? String,
                  AgentPaneFeatureTipRecords.isName(id) {
            let feature = params["feature"] as? String
            guard keys.count == 1 || feature.map(AgentPaneFeatureTipRecords.isName) == true else { return nil }
            self = .claim(id: id, feature: feature)
        } else {
            return nil
        }
    }
}
