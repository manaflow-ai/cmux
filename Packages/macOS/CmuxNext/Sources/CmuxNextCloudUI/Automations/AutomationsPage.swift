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

    @ObservationIgnored private let local: @Sendable () async throws -> Data
    @ObservationIgnored private let cloud: @Sendable () async throws -> Data

    /// Makes the page.
    ///
    /// - Parameters:
    ///   - local: This Mac's `cmux automation list --json` output.
    ///   - cloud: The `value` of a Cloud `automation.list`.
    public init(local: @escaping @Sendable () async throws -> Data, cloud: @escaping @Sendable () async throws -> Data) {
        self.local = local
        self.cloud = cloud
    }

    /// The page with `rows` already loaded (previews, screenshots).
    public convenience init(rows: [AutomationRow], selection: AutomationRow.ID? = nil) {
        self.init(local: { Data() }, cloud: { Data() })
        self.rows = rows
        self.selection = selection ?? rows.first?.id
    }

    /// Loads both sources; one that fails keeps the other's rows and records why.
    public func reload(now: Date) async {
        let (local, cloud) = (local, cloud)
        async let mine = attempt(local)
        async let theirs = attempt(cloud)
        var next: [AutomationRow] = []
        var problems: [AutomationRow.Target: String] = [:]
        switch await mine {
        case let .success(data): next += AutomationRow.local(data)
        case let .failure(error): problems[.thisMac] = (error as? AutomationsPageHost.SourceError)?.code ?? "unreachable"
        }
        switch await theirs {
        case let .success(data): next += AutomationRow.cloud(data)
        case let .failure(error): problems[.cloud] = (error as? AutomationsPageHost.SourceError)?.code ?? "unreachable"
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
}

/// One source's load, its error kept instead of thrown.
private nonisolated func attempt(_ body: @Sendable () async throws -> Data) async -> Result<Data, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
