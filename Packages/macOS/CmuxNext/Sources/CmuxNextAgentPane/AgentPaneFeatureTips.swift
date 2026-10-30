public import Foundation

/// The app's feature tip records (`tips.state`; leo-workspace design/feature-tips.md): which tips
/// were closed with their X, whose feature was used, and on how many launches each showed. An agent
/// page's own storage ends with the launch (``AgentPaneView`` uses a store that is not persistent),
/// so the app keeps them on this Mac across relaunches, as it keeps ``AgentPaneLastPicks``. Client
/// view state: never cmux.json and never the daemon. The page decides when a tip shows
/// (webviews/src/ui/featureTips/policy.ts); this only keeps what it reports.
///
/// Every pane's model reads and writes the same records (one defaults key), so it needs no shared
/// instance.
///
/// ```swift
/// AgentPaneFeatureTipRecords().keep("agents-drive-visible-browser-tabs", "closed")
/// ```
public final class AgentPaneFeatureTipRecords {
    static let defaultsKey = "agentPane.featureTips"
    /// The most tips kept; a highlight gets a tip rarely, so this bounds a misbehaving page only.
    static let maxRecords = 256

    private let defaults: UserDefaults

    /// Records kept in `defaults` (a test's own suite).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every record by tip id: `closed`, `used` or `shown:N`.
    public var records: [String: String] {
        (defaults.dictionary(forKey: Self.defaultsKey) ?? [:]).compactMapValues { $0 as? String }
    }

    /// Keeps `state` for tip `id`. A closed or used tip stays so: neither ever shows again.
    ///
    /// - Returns: Every record after the write.
    @discardableResult
    public func keep(_ id: String, _ state: String) -> [String: String] {
        var all = records
        if all[id] == "closed" || all[id] == "used" { return all }
        if all[id] == nil, all.count >= Self.maxRecords { return all }
        all[id] = state
        defaults.set(all, forKey: Self.defaultsKey)
        return all
    }

    /// Whether a page may keep `state` for `id`: a highlight id (lower-case letters, digits and
    /// dashes) and `closed`, `used` or `shown:1` to `shown:99`.
    public nonisolated static func accepts(id: String, state: String) -> Bool {
        let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard (1...80).contains(id.utf8.count), id.unicodeScalars.allSatisfy(idCharacters.contains) else { return false }
        if state == "closed" || state == "used" { return true }
        guard state.hasPrefix("shown:"), let count = Int(state.dropFirst("shown:".count)) else { return false }
        return (1...99).contains(count)
    }
}

extension AgentPaneModel {
    /// `tips.state {}` reads every record; `tips.state {id, state}` keeps one. Both answer
    /// `{states}`. A page on an app without this op shows no tip, since none could stay closed.
    func featureTipState(id: String?, state: String?) -> [String: Any] {
        let records = featureTipRecords
        guard let id, let state else { return AgentPaneReply.success(["states": records.records]) }
        return AgentPaneReply.success(["states": records.keep(id, state)])
    }
}
