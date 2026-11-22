public import Foundation
public import Observation

/// The Automations page model (docs/automations-platonic-ideal.md section 8, option A): every
/// automation of this Mac and of cmux Cloud in one list, grouped so failures come first and
/// successful runs stay quiet.
///
/// Sources and actions are injected, so the page is testable without the app:
///
/// ```swift
/// let page = AutomationsPage(
///     local: { try await cli(["automation", "list", "--json"]) },
///     cloud: { try await app("cloud.automation", ["op": "automation.list"]) })
/// await page.reload(now: .now)
/// ```
@MainActor @Observable
public final class AutomationsPage {
    /// One group of the list, in page order.
    public enum Section: Int, CaseIterable, Sendable {
        case needsYou, today, later, paused
    }

    /// Every row, newest load.
    public private(set) var rows: [AutomationRow] = []
    /// The row whose detail shows.
    public var selection: AutomationRow.ID?
    /// Why a source could not load, per source: the ``AutomationsPageHost/SourceError`` code
    /// (`automation.signed_out`, `feature.disabled`, `no_cli`, `cli_failed`), else `unreachable`.
    public private(set) var problems: [AutomationRow.Target: String] = [:]

    /// This Mac's runner, nil until loaded (or from a CLI that does not say).
    public private(set) var runner: RunnerHealth?
    /// The New or Edit form the detail shows in place of the automation, nil when none.
    public var draft: AutomationDraft?
    /// Why the last button's command failed (the CLI's words), shown beside the buttons.
    public var actionError: String?
    /// The form's save is running (its button shows it and does not fire twice).
    public private(set) var saving = false
    /// The run whose log shows under it, and the log's text.
    public private(set) var shownLog: (run: String, text: String)?
    /// The automation whose Delete asks to confirm.
    public var confirmingDelete: AutomationRow.ID?

    @ObservationIgnored private let local: @Sendable () async throws -> Data
    @ObservationIgnored private let cloud: @Sendable () async throws -> Data
    @ObservationIgnored private let history: (@Sendable () async throws -> Data)?
    @ObservationIgnored private let cloudHistory: (@Sendable () async throws -> Data)?
    /// Runs `cmux --json WORDS…` and returns its stdout; throws ``AutomationsPageHost/SourceError``
    /// with the CLI's message when it fails. Nil: the page has no buttons.
    @ObservationIgnored public let cli: (@Sendable ([String]) async throws -> Data)?

    /// Makes the page.
    ///
    /// - Parameters:
    ///   - local: This Mac's `cmux automation list --json` output.
    ///   - cloud: The `value` of a Cloud `automation.list`.
    ///   - history: This Mac's `cmux automation history --json` output.
    ///   - cloudHistory: Every Cloud run (`cmux automation history --target cloud --json`).
    ///   - cli: Runs one `cmux --json automation …` command (the buttons and the form).
    public init(local: @escaping @Sendable () async throws -> Data, cloud: @escaping @Sendable () async throws -> Data,
                history: (@Sendable () async throws -> Data)? = nil,
                cloudHistory: (@Sendable () async throws -> Data)? = nil,
                cli: (@Sendable ([String]) async throws -> Data)? = nil) {
        self.local = local
        self.cloud = cloud
        self.history = history
        self.cloudHistory = cloudHistory
        self.cli = cli
    }

    /// The page with `rows` already loaded (previews, screenshots).
    public convenience init(rows: [AutomationRow], selection: AutomationRow.ID? = nil) {
        self.init(local: { Data() }, cloud: { Data() })
        self.rows = rows
        self.selection = selection ?? rows.first?.id
    }

    /// Loads both sources; one that fails keeps the other's rows and records why.
    public func reload(now: Date) async {
        let (local, cloud, history, cloudHistory) = (local, cloud, history, cloudHistory)
        async let mine = attempt(local)
        async let theirs = attempt(cloud)
        async let runs = attempt(history ?? { Data() })
        async let cloudRuns = attempt(cloudHistory ?? { Data() })
        var next: [AutomationRow] = []
        var problems: [AutomationRow.Target: String] = [:]
        switch await mine {
        case let .success(data):
            let byAutomation = (try? (await runs).get()).map { AutomationRow.runs($0, seenAt: AutomationRow.seenAt(data)) } ?? [:]
            next += AutomationRow.local(data).map { row in
                var row = row
                row.runs = byAutomation[row.id] ?? []
                return row
            }
            runner = AutomationRow.runner(data)
        case let .failure(error):
            problems[.thisMac] = (error as? AutomationsPageHost.SourceError)?.code ?? "unreachable"
            _ = await runs
        }
        switch await theirs {
        case let .success(data):
            let cloudRows = AutomationRow.cloud(data)
            let commands = Set(cloudRows.filter { $0.kind == .command }.map(\.id))
            let byAutomation = (try? (await cloudRuns).get()).map { AutomationRow.cloudRuns($0, commands: commands) } ?? [:]
            next += cloudRows.map { row in
                var row = row
                row.runs = byAutomation[row.id] ?? []
                if let newest = row.runs.first { row.last = newest.result }
                return row
            }
        case let .failure(error):
            problems[.cloud] = (error as? AutomationsPageHost.SourceError)?.code ?? "unreachable"
            _ = await cloudRuns
        }
        rows = next
        self.problems = problems
        if selection == nil || !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
    }

    /// The section a row belongs to at `now`.
    public static func section(of row: AutomationRow, now: Date, calendar: Calendar = .current) -> Section {
        if !row.enabled { return .paused }
        if row.needsYou { return .needsYou }
        if let next = row.nextRun, calendar.isDate(next, inSameDayAs: now) { return .today }
        return .later
    }

    /// The non-empty sections at `now`, each with its rows ordered by next run.
    public func sections(now: Date, calendar: Calendar = .current) -> [(Section, [AutomationRow])] {
        Section.allCases.compactMap { section in
            let members = rows
                .filter { Self.section(of: $0, now: now, calendar: calendar) == section }
                .sorted { ($0.nextRun ?? .distantFuture, $0.name) < ($1.nextRun ?? .distantFuture, $1.name) }
            return members.isEmpty ? nil : (section, members)
        }
    }

    /// The badge on the sidebar row: failures only (silence is success).
    public var badgeCount: Int { rows.filter(\.needsYou).count }

    /// The selected row.
    public var selected: AutomationRow? { rows.first { $0.id == selection } }

    // MARK: Buttons

    /// The CLI words for `verb` on `row`: Cloud rows go to the Cloud with `--target cloud`.
    public static func words(_ verb: String, _ row: AutomationRow, _ extra: [String] = []) -> [String] {
        ["automation", verb, row.id] + extra + (row.target == .cloud ? ["--target", "cloud"] : [])
    }

    /// Runs `words`, then reloads. False (and ``actionError`` set) when the CLI refused.
    @discardableResult
    public func perform(_ words: [String], now: Date = .now) async -> Bool {
        guard let cli else { return false }
        do {
            _ = try await cli(words)
            actionError = nil
            await reload(now: now)
            return true
        } catch {
            actionError = (error as? AutomationsPageHost.SourceError)?.description ?? String(describing: error)
            await reload(now: now)
            return false
        }
    }

    /// Run now: one manual run; a second press while it runs is recorded as skipped, never doubled.
    public func runNow(_ row: AutomationRow) async { await perform(Self.words("run", row)) }

    /// Pause or resume its schedule.
    public func setEnabled(_ row: AutomationRow, _ enabled: Bool) async {
        await perform(Self.words(enabled ? "resume" : "pause", row))
    }

    /// Deletes it (its run history is kept on disk); only after ``confirmingDelete`` said yes.
    public func delete(_ row: AutomationRow) async {
        confirmingDelete = nil
        if await perform(Self.words("delete", row, ["--yes"])), selection == row.id { selection = rows.first?.id }
    }

    /// The person looked at its runs: its failures are read.
    public func markSeen(_ row: AutomationRow) async {
        guard row.target == .thisMac, row.unread > 0 || row.runs.contains(where: \.unread), let cli else { return }
        _ = try? await cli(Self.words("seen", row))
        if let i = rows.firstIndex(where: { $0.id == row.id }) {
            rows[i].unread = 0
            for j in rows[i].runs.indices { rows[i].runs[j].unread = false }
        }
    }

    /// Starts this Mac's runner (a login item that keeps running with the app closed).
    public func startRunner() async { await perform(["automation", "runner", "install"]) }

    /// Shows `run`'s log under its row, or hides it when it shows.
    public func toggleLog(_ run: AutomationRow.Run) async {
        if shownLog?.run == run.id { shownLog = nil; return }
        guard let cli else { return }
        do {
            let cloud = rows.contains { $0.target == .cloud && $0.runs.contains { $0.id == run.id } }
            let data = try await cli(["automation", "logs", run.id] + (cloud ? ["--target", "cloud"] : []))
            shownLog = (run.id, await Self.logTail(data))
        } catch {
            shownLog = (run.id, (error as? AutomationsPageHost.SourceError)?.description ?? String(describing: error))
        }
    }

    /// `cmux automation show-page --name NAME`: selects the automation with that id or name (any
    /// case) and opens the log of its newest run that has one. False when no automation matches.
    @discardableResult
    public func show(named name: String, now: Date = .now) async -> Bool {
        await reload(now: now)
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard let row = rows.first(where: { $0.id == wanted })
            ?? rows.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else { return false }
        selection = row.id
        if let run = row.runs.first(where: { $0.logPath != nil }), shownLog?.run != run.id { await toggleLog(run) }
        return true
    }

    /// The tail of an `automation logs` answer's `log`, read off the main actor: a log has no size bound.
    @concurrent nonisolated static func logTail(_ data: Data) async -> String {
        tail(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["log"] as? String ?? "")
    }

    /// The `id` of a save answer, read off the main actor.
    @concurrent nonisolated static func savedID(_ data: Data) async -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String
    }

    /// The last 40 lines of a log, so a long one never floods the page.
    nonisolated static func tail(_ text: String, lines: Int = 40) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Saves the form: a new automation or the edit. Keeps the form open with the CLI's words
    /// when it refuses; closes it and selects the automation when it saved.
    public func save(now: Date = .now) async {
        guard let draft, draft.problems.isEmpty, !saving, let cli else { return }
        saving = true
        defer { saving = false }
        do {
            let data = try await cli(draft.arguments)
            actionError = nil
            let id = await Self.savedID(data)
            self.draft = nil
            await reload(now: now)
            if let id = id ?? draft.editing { selection = id }
        } catch {
            actionError = (error as? AutomationsPageHost.SourceError)?.description ?? String(describing: error)
        }
    }
}

/// One source's load, its error kept instead of thrown.
private nonisolated func attempt(_ body: @Sendable () async throws -> Data) async -> Result<Data, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
