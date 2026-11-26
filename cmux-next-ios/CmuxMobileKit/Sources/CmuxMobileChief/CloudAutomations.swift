import CmuxMobileDesign
import Foundation
import CmuxMobileModel
import Observation

/// One of the account's Cloud automations as the phone's Automations page shows it (the Mac's
/// `AutomationRow`, Cloud source): `automation.list` for the definitions and one
/// `automation.runs.list` for the newest runs, which give each its last result.
public struct CloudAutomation: Codable, Identifiable, Hashable, Sendable {
    public enum LastResult: String, Codable, Hashable, Sendable {
        case none, succeeded, failed, running, skipped
    }

    public struct Run: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var at: Date
        public var result: LastResult
        /// The run's error in the service's words, or its state when it has none.
        public var reason: String?
        /// How it started (`manual`, `cron`, `every`, `webhook`).
        public var trigger: String
    }

    public var id: String
    public var name: String
    /// The schedule in words (`cron 0 9 * * 1-5 (UTC)`, `every 30m`, `manual`).
    public var schedule: String
    /// The prompt or command a run does.
    public var task: String
    public var enabled: Bool
    public var version: Int
    public var nextRun: Date?
    public var runs: [Run] = []

    public var last: LastResult { runs.first?.result ?? .none }
    /// A failed last run on an automation still on: it goes to "Needs you".
    public var needsYou: Bool { enabled && last == .failed }

    /// The automations of an `automation.list` value (times in milliseconds).
    public static func list(_ value: Data) -> [CloudAutomation] {
        guard let root = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any],
              let items = root["automations"] as? [[String: Any]] else { return [] }
        return parse(items)
    }

    static func parse(_ items: [[String: Any]]) -> [CloudAutomation] {
        items.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let body = item["body"] as? [String: Any] ?? [:]
            let specs = (item["triggers"] as? [[String: Any]] ?? []).map { $0["spec"] as? [String: Any] ?? $0 }
            let schedule = specs.first { ($0["type"] as? String) != "manual" }.map(describe) ?? describe(["type": "manual"])
            return CloudAutomation(id: id, name: name, schedule: schedule,
                                   task: body["prompt"] as? String ?? body["instructions"] as? String ?? body["command"] as? String ?? "",
                                   enabled: item["enabled"] as? Bool ?? true, version: (item["version"] as? NSNumber)?.intValue ?? 0,
                                   nextRun: milliseconds(item["next_run_at"]))
        }
    }

    /// The runs of an `automation.runs.list` value by automation, newest first.
    public static func runs(_ value: Data) -> [String: [Run]] {
        guard let root = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any],
              let items = root["runs"] as? [[String: Any]] else { return [:] }
        return parseRuns(items)
    }

    static func parseRuns(_ items: [[String: Any]]) -> [String: [Run]] {
        var out: [String: [Run]] = [:]
        for item in items {
            guard let id = item["id"] as? String, let automation = item["automation"] as? String,
                  let at = milliseconds(item["finished_at"]) ?? milliseconds(item["started_at"]) ?? milliseconds(item["created_at"]) else { continue }
            let state = item["state"] as? String
            let error = (item["error"] as? [String: Any]).flatMap { $0["message"] as? String ?? $0["code"] as? String }
            let trigger = (item["trigger"] as? [String: Any])?["type"] as? String ?? "manual"
            out[automation, default: []].append(Run(id: id, at: at, result: result(state), reason: error ?? (result(state) == .failed ? state : nil),
                                                    trigger: trigger))
        }
        return out.mapValues { $0.sorted { $0.at > $1.at } }
    }

    static func milliseconds(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    static func result(_ state: String?) -> LastResult {
        switch state {
        case "succeeded": .succeeded
        case "failed", "dead", "cancelled": .failed
        case "running", "queued", "sleeping", "waiting": .running
        case "skipped": .skipped
        default: .none
        }
    }

    static func describe(_ trigger: [String: Any]) -> String {
        switch trigger["type"] as? String {
        case "cron": "cron \(trigger["expr"] as? String ?? "") (\(trigger["tz"] as? String ?? "UTC"))"
        case "every": "every \(((trigger["seconds"] as? NSNumber)?.intValue ?? 0) / 60)m"
        case "webhook": "webhook"
        case "at": "once"
        default: "manual"
        }
    }
}

/// The Automations page's model (the Mac's `AutomationsPage`, Cloud source only: this Mac's
/// local runner is the Mac's own): the list in sections, and Run now, Pause or Resume and Delete,
/// each an op the account makes with its own token.
@MainActor
@Observable
public final class CloudAutomationsModel {
    public enum Section: Int, CaseIterable, Sendable {
        case needsYou, today, later, paused

        public var title: String {
            switch self {
            case .needsYou: String(localized: "Needs you")
            case .today: String(localized: "Today")
            case .later: String(localized: "Later")
            case .paused: String(localized: "Paused")
            }
        }
    }

    public enum Phase: Equatable, Sendable {
        case loading, loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var automations: [CloudAutomation] = []
    /// The automation an action runs on now (its row shows progress).
    public private(set) var busyID: String?
    /// An automation's page is up: its own alert shows a refusal, not the list's.
    public var showsDetail = false
    /// The last action's refusal, for an alert.
    public var failure: String?
    /// A refresh that could not reach cmux Cloud while the page keeps its rows: said only once the
    /// outage has lasted ``QuietStatusGate/threshold`` (Leo, 2026-11-16: "obviously if it isn't
    /// interactive im not connected"). A refusal the person must act on stays in ``failure``, at once.
    @ObservationIgnored let unreachedQuiet = QuietStatusGate()
    private var unreached: String?
    /// The alert's text: an action's refusal at once, a refresh that could not reach the service
    /// only past the hold.
    public var shownFailure: String? { failure ?? (unreachedQuiet.isShown ? unreached : nil) }
    public func dismissFailure() { failure = nil; unreached = nil }
    /// The automation the last Run now started (its page says so).
    public private(set) var startedID: String?

    @ObservationIgnored private let account: @MainActor () -> AccountCloud?
    @ObservationIgnored private let cache: LastKnownList?
    @ObservationIgnored private var refreshID = 0

    public init(cache: LastKnownList? = nil, account: @escaping @MainActor () -> AccountCloud?) {
        self.account = account
        self.cache = cache
        restoreCache()
    }

    /// The page from ``ChiefSources``' signed-in account.
    public static func live(_ sources: ChiefSources = .shared) -> CloudAutomationsModel {
        let source = sources.personalListSource("cloud-automations")
        return CloudAutomationsModel(cache: source.cache, account: source.account)
    }

    private func restoreCache() {
        guard let saved = cache?.read([CloudAutomation].self) else { return }
        automations = saved
        phase = .loaded
    }

    public func load(reportFailure: Bool = false) async {
        refreshID += 1
        let current = refreshID
        guard let account = account() else {
            phase = .failed(String(localized: "Sign in to cmux to see your Cloud automations."))
            return
        }
        // Only a page that has not loaded shows the spinner: a reload after the last automation
        // was deleted keeps the (empty) list, so a reload that is cancelled never strands it on
        // "Loading" (live run of this batch).
        let before = phase
        if automations.isEmpty, phase != .loaded { phase = .loading }
        do {
            async let listed = account.read("automation.list", params: ["limit": 100])
            async let ran = account.read("automation.runs.list", params: ["limit": 200])
            var rows = CloudAutomation.parse(try AccountCloud.listItems("automations", in: await listed))
            let runs = (try? await ran).flatMap { value in
                (try? AccountCloud.listItems("runs", in: value)).map { CloudAutomation.parseRuns($0) }
            }
            let history = runs ?? automations.reduce(into: [:]) { $0[$1.id] = $1.runs }
            for index in rows.indices { rows[index].runs = history[rows[index].id] ?? [] }
            guard current == refreshID, self.account() != nil, !Task.isCancelled else { return }
            automations = rows
            phase = .loaded
            cache?.save(rows.map { row in
                // The list needs the last outcome. Prompts, commands and error text are detail data.
                var summary = row
                summary.task = ""
                summary.runs = row.runs.prefix(1).map { run in
                    var last = run
                    last.reason = nil
                    return last
                }
                return summary
            })
            unreached = nil
            unreachedQuiet.update(down: false)
        } catch is CancellationError {
            guard current == refreshID, self.account() != nil else { return }
            // A cancelled reload puts back what the page showed (never a spinner left behind).
            phase = before
            return
        } catch {
            guard current == refreshID, self.account() != nil else { return }
            let message = Self.message(error)
            if phase != .loaded {
                phase = .failed(message)
            } else if AccountCloud.isUnreachable(error), CmuxMobilePreferences.quietCloudConnect() {
                unreached = message
                unreachedQuiet.update(down: true)
            } else if reportFailure {
                failure = message
            }
        }
    }

    /// The non-empty sections at `now`, each ordered by next run then name (the Mac's order).
    public func sections(now: Date, calendar: Calendar = .current) -> [(Section, [CloudAutomation])] {
        Section.allCases.compactMap { section in
            let rows = automations.filter { Self.section(of: $0, now: now, calendar: calendar) == section }
                .sorted { ($0.nextRun ?? .distantFuture, $0.name) < ($1.nextRun ?? .distantFuture, $1.name) }
            return rows.isEmpty ? nil : (section, rows)
        }
    }

    public static func section(of row: CloudAutomation, now: Date, calendar: Calendar = .current) -> Section {
        if !row.enabled { return .paused }
        if row.needsYou { return .needsYou }
        if let next = row.nextRun, calendar.isDate(next, inSameDayAs: now) { return .today }
        return .later
    }

    public func automation(_ id: String) -> CloudAutomation? { automations.first { $0.id == id } }

    /// Run now: one run of the automation (`automation.run`), then the list again.
    public func runNow(_ row: CloudAutomation) async {
        guard canAct else { return }
        startedID = nil
        await act(row) { account in
            _ = try await account.mutate("automation.run", params: ["automation": row.id], key: "run-\(row.id)-\(UUID().uuidString.lowercased())")
            self.startedID = row.id
        }
    }

    /// No other action is running and the account is signed in: an action may start (checked
    /// before anything shows, so nothing changes on the phone that the service never got).
    public var canAct: Bool { busyID == nil && account() != nil }

    /// Pause or Resume (`automation.update {enabled}` at its version). Shown at once; the
    /// service's answer settles it.
    public func setEnabled(_ row: CloudAutomation, _ enabled: Bool) async {
        guard canAct, let index = automations.firstIndex(where: { $0.id == row.id }) else { return }
        startedID = nil
        let old = automations[index]
        automations[index].enabled = enabled
        await act(row, rollback: { [weak self] in
            if let at = self?.automations.firstIndex(where: { $0.id == old.id }) { self?.automations[at] = old }
        }) { account in
            _ = try await account.mutate("automation.update",
                                         params: ["automation": row.id, "enabled": enabled, "expected_version": row.version],
                                         key: "enable-\(row.id)-\(row.version)-\(enabled)")
        }
    }

    /// Delete (`automation.delete`): gone from the list at once; its run history stays on the service.
    public func delete(_ row: CloudAutomation) async {
        guard canAct, let index = automations.firstIndex(where: { $0.id == row.id }) else { return }
        startedID = nil
        let old = automations
        automations.remove(at: index)
        await act(row, rollback: { [weak self] in self?.automations = old }) { account in
            _ = try await account.mutate("automation.delete", params: ["automation": row.id], key: "delete-\(row.id)")
        }
    }

    private func act(_ row: CloudAutomation, rollback: (() -> Void)? = nil,
                     _ work: @MainActor (AccountCloud) async throws -> Void) async {
        guard busyID == nil, let account = account() else {
            rollback?()
            return
        }
        busyID = row.id
        defer { busyID = nil }
        do {
            try await work(account)
            await load()
        } catch is CancellationError {
            rollback?()
        } catch {
            rollback?()
            failure = Self.message(error)
        }
    }

    static func message(_ error: any Error) -> String {
        switch error {
        case let failure as AccountCloud.Failure:
            switch failure.code {
            case "feature.disabled": String(localized: "Your administrator turned off cmux Cloud, so Cloud automations are not shown.")
            case "auth.unauthenticated": String(localized: "Sign in to cmux to see your Cloud automations.")
            default: failure.description
            }
        default: String(localized: "Couldn't reach cmux Cloud. Check your connection.")
        }
    }
}
