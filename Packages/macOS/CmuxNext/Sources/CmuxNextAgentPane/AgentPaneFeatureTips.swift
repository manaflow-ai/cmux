public import AppKit
public import Foundation

/// The app's feature tip records (`tips.state`; leo-workspace design/feature-tips.md): which tips
/// were closed with their X, whose feature was used, and on how many launches each showed. An agent
/// page's own storage ends with the launch (``AgentPaneView`` uses a store that is not persistent),
/// so the app keeps them on this Mac across relaunches, as it keeps ``AgentPaneLastPicks``. It also
/// answers which page shows this launch's one tip (``claim(_:)``): pages share no storage (a WebKit
/// chat page has a store of its own), and the main actor answers claims one at a time. Client
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

    static let launchKey = "agentPane.featureTips.launch"

    private let defaults: UserDefaults
    private let launch: String

    /// Records kept in `defaults` (a test's own suite), for the launch `launch` names.
    public init(defaults: UserDefaults = .standard, launch: String = AgentPaneFeatureTipRecords.thisLaunch) {
        self.defaults = defaults
        self.launch = launch
    }

    /// This process: its id and when it started, which no later launch repeats.
    public static var thisLaunch: String {
        let started = NSRunningApplication.current.launchDate?.timeIntervalSince1970 ?? 0
        return "\(ProcessInfo.processInfo.processIdentifier)@\(Int(started))"
    }

    /// Takes this launch's one tip for `id`: true for the launch's first claim, false for every
    /// later one, whichever page or window asks.
    public func claim(_ id: String) -> Bool {
        if defaults.string(forKey: Self.launchKey)?.hasPrefix("\(launch) ") == true { return false }
        defaults.set("\(launch) \(id)", forKey: Self.launchKey)
        return true
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
    /// `tips.state {}` reads every record and `tips.state {id, state}` keeps one, both answering
    /// `{states}`; `tips.state {claim}` takes this launch's one tip, answering `{claimed}`. A page on an
    /// app without this op shows no tip, since none could stay closed.
    func featureTipState(_ request: AgentPaneFeatureTipRequest) -> [String: Any] {
        let records = featureTipRecords
        switch request {
        case .read: return AgentPaneReply.success(["states": records.records])
        case .keep(let id, let state): return AgentPaneReply.success(["states": records.keep(id, state)])
        case .claim(let id): return AgentPaneReply.success(["claimed": records.claim(id)])
        }
    }
}

/// What a page asks of `tips.state`.
public nonisolated enum AgentPaneFeatureTipRequest: Equatable, Sendable {
    case read
    case keep(id: String, state: String)
    case claim(id: String)

    /// The request `params` make, or nil for params a page may not send.
    public init?(_ params: [String: Any]?) {
        let params = params ?? [:]
        let keys = Set(params.keys)
        if keys.isEmpty {
            self = .read
        } else if keys == ["id", "state"], let id = params["id"] as? String, let state = params["state"] as? String,
                  AgentPaneFeatureTipRecords.accepts(id: id, state: state) {
            self = .keep(id: id, state: state)
        } else if keys == ["claim"], let id = params["claim"] as? String,
                  AgentPaneFeatureTipRecords.accepts(id: id, state: "used") {
            self = .claim(id: id)
        } else {
            return nil
        }
    }
}
