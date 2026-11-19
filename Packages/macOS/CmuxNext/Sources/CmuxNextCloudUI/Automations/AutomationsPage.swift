public import CmuxVisibleRows
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
public final class AutomationsPage: VisibleRowsList {
    /// One group of the list, in page order.
    public enum Section: Int, CaseIterable, Sendable {
        case needsYou, today, later, paused
    }

    /// Every row, newest load.
    public private(set) var rows: [AutomationRow] = []
    /// The enabled rows, counted once per load.
    public private(set) var activeCount = 0
    /// The row whose detail shows.
    public var selection: AutomationRow.ID?
    /// Why a source could not load, per source: the ``AutomationsPageHost/SourceError`` code
    /// (`automation.signed_out`, `feature.disabled`, `no_cli`, `cli_failed`), else `unreachable`.
    public private(set) var problems: [AutomationRow.Target: String] = [:]

    /// The list's row work (the visible-rows contract): rows configured, and rows walked by a load and a sort.
    @ObservationIgnored public let listWork = ListWorkMeter()
    /// List rows on screen now: each counts itself on appear and off on disappear.
    @ObservationIgnored public internal(set) var rowViewsAlive = 0
    /// How many times ``sections(now:calendar:)`` grouped and sorted every row (the row-count tests).
    @ObservationIgnored private(set) var sectionBuilds = 0
    /// Loads so far: the sections and places below hold for the load they were made in.
    @ObservationIgnored private var loads = 0
    /// Each row's index in ``rows`` (the first, should two share an id), made with each load.
    @ObservationIgnored private var places: [AutomationRow.ID: Int] = [:]
    /// The last ``sections(now:calendar:)``, kept until the next load or another time.
    @ObservationIgnored private var arranged: (load: Int, now: Date, calendar: Calendar, sections: [(Section, [AutomationRow])])?
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
        load(rows)
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
        load(next)
        self.problems = problems
        if selection.flatMap({ places[$0] }) == nil { selection = rows.first?.id }
    }

    /// Shows `next`: counts its enabled rows and indexes it once, so a body reads both without a pass over the rows.
    private func load(_ next: [AutomationRow]) {
        rows = next
        loads += 1
        listWork.walked(next.count)
        activeCount = next.filter(\.enabled).count
        places = Dictionary(next.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The section a row belongs to at `now`.
    public static func section(of row: AutomationRow, now: Date, calendar: Calendar = .current) -> Section {
        if !row.enabled { return .paused }
        if row.needsYou { return .needsYou }
        if let next = row.nextRun, calendar.isDate(next, inSameDayAs: now) { return .today }
        return .later
    }

    /// The non-empty sections at `now`, each with its rows ordered by next run. Grouped and sorted once per
    /// load and time: a body that reads them again (a new selection) gets the same sections.
    public func sections(now: Date, calendar: Calendar = .current) -> [(Section, [AutomationRow])] {
        let rows = rows // read here, so a body that shows the sections follows a load
        if let arranged, arranged.load == loads, arranged.now == now, arranged.calendar == calendar { return arranged.sections }
        sectionBuilds += 1
        listWork.walked(rows.count)
        let sections: [(Section, [AutomationRow])] = Section.allCases.compactMap { section in
            let members = rows
                .filter { Self.section(of: $0, now: now, calendar: calendar) == section }
                .sorted { ($0.nextRun ?? .distantFuture, $0.name) < ($1.nextRun ?? .distantFuture, $1.name) }
            return members.isEmpty ? nil : (section, members)
        }
        arranged = (loads, now, calendar, sections)
        return sections
    }

    /// The badge on the sidebar row: failures only (silence is success).
    public var badgeCount: Int { rows.filter(\.needsYou).count }

    /// The selected row.
    public var selected: AutomationRow? {
        let rows = rows
        return selection.flatMap { places[$0] }.map { rows[$0] }
    }
}

/// One source's load, its error kept instead of thrown.
private nonisolated func attempt(_ body: @Sendable () async throws -> Data) async -> Result<Data, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
