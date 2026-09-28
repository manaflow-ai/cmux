import CmuxAgentChat
import Foundation
import Observation

/// Supplies the prompt outline of the agent session in a terminal surface.
@MainActor
protocol AgentTurnOutlineSource: AnyObject {
    func turnOutlineChanges(surfaceID: UUID) -> AsyncStream<Void>
    func turnOutline(surfaceID: UUID) async -> AgentTurnOutlineSnapshot?
}

extension AgentChatTranscriptService: AgentTurnOutlineSource {}

/// The terminal a turn rail reads rows from and scrolls.
@MainActor
protocol AgentTurnTerminalViewport: AnyObject {
    /// Current scrollback geometry and row-space revision.
    func agentTurnRailGeometry() -> NotificationScrollRestoreGeometry?
    /// Every screen row, top to bottom, one line per physical row.
    func agentTurnRailScreenRows() -> String?
    /// Scrolls so `row` is the top viewport row, only if the row space is
    /// still `revision`.
    func agentTurnRailScroll(toRow row: Int, revision: UInt64, isAtBottom: Bool) -> Bool
    /// Whether the terminal is on screen. Scrollback is read in the
    /// background only for visible terminals; hidden ones resolve on demand.
    var agentTurnRailIsOnScreen: Bool { get }
}

/// State behind one terminal's turn rail: the session's prompts, where each
/// prompt sits in scrollback, and which turn is on screen.
///
/// The prompt list comes from the agent's transcript (the same outline any
/// other turn navigator reads); the terminal only supplies row positions. A
/// prompt that cannot be found in scrollback stays listed but is not
/// jumpable, so a jump never lands on the wrong exchange.
@MainActor
@Observable
final class AgentTurnRailModel {
    /// Minimum prompts before the rail shows.
    static let minimumVisibleTurns = 2

    let surfaceID: UUID
    private(set) var entries: [ChatOutlineEntry] = []
    private(set) var agentKind: ChatAgentKind?
    /// Resolved start row per entry id; absent when not in scrollback.
    private(set) var anchorRows: [String: Int] = [:]
    /// Whether rows have been resolved at least once for the current entries.
    private(set) var hasResolvedAnchors = false
    /// The turn whose exchange is on screen.
    private(set) var currentIndex: Int?

    /// Whether the rail should be shown: a recognized agent session with at
    /// least ``minimumVisibleTurns`` prompts.
    var isVisible: Bool {
        agentKind != nil && entries.count >= Self.minimumVisibleTurns
    }

    /// Whether the terminal keeps a rail gutter: any live agent session,
    /// even before its second prompt, so the terminal does not reflow the
    /// agent's interface when the rail first appears.
    var reservesGutter: Bool {
        agentKind != nil
    }

    /// Called when ``isVisible`` or ``reservesGutter`` flips, so the host can
    /// lay out the gutter and rail.
    @ObservationIgnored var onPresentationChange: (() -> Void)?

    @ObservationIgnored private weak var source: (any AgentTurnOutlineSource)?
    @ObservationIgnored private weak var viewport: (any AgentTurnTerminalViewport)?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let resolveInterval: Duration
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var needsResolve = false
    @ObservationIgnored private var resolvedRevision: UInt64?
    @ObservationIgnored private var resolvedEntryIDs: [String] = []
    @ObservationIgnored private var resolvedTotalRows: UInt64 = 0
    /// Re-resolves spent waiting for the newest prompt to be echoed.
    @ObservationIgnored private var tailRetryCount = 0
    /// Cap on those retries: a prompt the agent never echoes verbatim (a
    /// pasted-text placeholder) must not keep re-reading scrollback while the
    /// agent streams output.
    private static let maximumTailRetries = 5
    @ObservationIgnored private var lastGeometry: GhosttyScrollbarSnapshot?

    init(
        surfaceID: UUID,
        clock: any Clock<Duration> = ContinuousClock(),
        resolveInterval: Duration = .milliseconds(400)
    ) {
        self.surfaceID = surfaceID
        self.clock = clock
        self.resolveInterval = resolveInterval
    }

    deinit {
        observeTask?.cancel()
        resolveTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts following the surface's session. Idempotent.
    func start(source: any AgentTurnOutlineSource, viewport: any AgentTurnTerminalViewport) {
        self.viewport = viewport
        if self.source === source, observeTask != nil { return }
        observeTask?.cancel()
        self.source = source
        let changes = source.turnOutlineChanges(surfaceID: surfaceID)
        observeTask = Task { [weak self] in
            await self?.refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    /// Stops following the session and hides the rail.
    func stop() {
        observeTask?.cancel()
        observeTask = nil
        resolveTask?.cancel()
        resolveTask = nil
        source = nil
        apply(snapshot: nil)
    }

    // MARK: - Outline

    /// Re-reads the outline from the source.
    func refresh() async {
        guard let source else { return }
        let snapshot = await source.turnOutline(surfaceID: surfaceID)
        guard !Task.isCancelled, self.source === source else { return }
        apply(snapshot: snapshot)
    }

    private func apply(snapshot: AgentTurnOutlineSnapshot?) {
        let wasVisible = isVisible
        let wasReserving = reservesGutter
        let nextEntries = snapshot?.entries ?? []
        agentKind = snapshot?.agentKind
        if nextEntries != entries {
            entries = nextEntries
            anchorRows = anchorRows.filter { id, _ in nextEntries.contains { $0.id == id } }
            scheduleResolve()
        }
        if nextEntries.isEmpty {
            anchorRows = [:]
            hasResolvedAnchors = false
            currentIndex = nil
        }
        if wasVisible != isVisible || wasReserving != reservesGutter {
            onPresentationChange?()
        }
    }

    // MARK: - Scrollback anchors

    /// Called on every scrollback geometry change.
    func viewportDidChange() {
        guard isVisible, let geometry = viewport?.agentTurnRailGeometry() else { return }
        let snapshot = GhosttyScrollbarSnapshot(geometry)
        lastGeometry = snapshot
        if needsResolve || needsReresolve(for: snapshot) {
            scheduleResolve()
        }
        updateCurrentIndex(snapshot)
    }

    /// Starts a resolve deferred while the terminal was hidden. Safe to call
    /// from layout: it mutates no observed state.
    func resumeDeferredResolve() {
        guard needsResolve, resolveTask == nil else { return }
        scheduleResolve()
    }

    private func needsReresolve(for geometry: GhosttyScrollbarSnapshot) -> Bool {
        guard hasResolvedAnchors else { return true }
        // Reflow, trimming, clearing or a screen switch renumbers rows.
        if geometry.revision != resolvedRevision { return true }
        // The newest prompt may be echoed after its transcript line landed.
        if let last = entries.last,
           anchorRows[last.id] == nil,
           geometry.total != resolvedTotalRows,
           tailRetryCount < Self.maximumTailRetries {
            tailRetryCount += 1
            return true
        }
        return false
    }

    /// Resolves anchors now, coalescing with a resolve already in flight.
    private func scheduleResolve() {
        guard isVisible else { return }
        needsResolve = true
        // A hidden terminal defers the read until it is shown (the next
        // layout or scrollbar update calls ``viewportDidChange()``) or a
        // jump needs rows.
        guard resolveTask == nil, viewport?.agentTurnRailIsOnScreen == true else { return }
        resolveTask = Task { [weak self] in
            await self?.runResolveLoop()
        }
    }

    private func runResolveLoop() async {
        defer { resolveTask = nil }
        while needsResolve, !Task.isCancelled {
            guard viewport?.agentTurnRailIsOnScreen == true else { return }
            needsResolve = false
            let started = ContinuousClock.now
            await resolveAnchors()
            let cost = ContinuousClock.now - started
            guard needsResolve else { return }
            // Scrollback is changing continuously (streaming output at the
            // scrollback limit renumbers rows on every trim). Bound how often
            // the full screen is read: at least `resolveInterval` apart, and
            // at most ~10% of wall time for very large scrollback.
            do {
                try await clock.sleep(for: max(resolveInterval, cost * 10))
            } catch {
                return
            }
        }
    }

    /// Reads scrollback once and resolves every entry's start row.
    @discardableResult
    func resolveAnchors() async -> Bool {
        guard let viewport,
              let geometry = viewport.agentTurnRailGeometry(),
              let rows = viewport.agentTurnRailScreenRows() else {
            return false
        }
        let entries = entries
        let resolved = await Task.detached(priority: .userInitiated) {
            ChatOutlineAnchorResolver().rows(for: entries, in: rows)
        }.value
        guard !Task.isCancelled, entries == self.entries else {
            needsResolve = true
            return false
        }
        if resolvedRevision != geometry.rowSpaceRevision || resolvedEntryIDs != entries.map(\.id) {
            tailRetryCount = 0
        }
        anchorRows = resolved
        hasResolvedAnchors = true
        resolvedRevision = geometry.rowSpaceRevision
        resolvedEntryIDs = entries.map(\.id)
        resolvedTotalRows = geometry.scrollbar.total
        if let current = viewport.agentTurnRailGeometry() {
            if current.rowSpaceRevision != geometry.rowSpaceRevision {
                needsResolve = true
            }
            let snapshot = GhosttyScrollbarSnapshot(current)
            lastGeometry = snapshot
            updateCurrentIndex(snapshot)
        }
        return true
    }

    @ObservationIgnored private var cachedNavigator: (ids: [String], rows: [String: Int], navigator: ChatOutlineNavigator)?

    private var navigator: ChatOutlineNavigator {
        let ids = entries.map(\.id)
        if let cachedNavigator, cachedNavigator.ids == ids, cachedNavigator.rows == anchorRows {
            return cachedNavigator.navigator
        }
        let navigator = ChatOutlineNavigator(anchorRows: ids.map { anchorRows[$0] })
        cachedNavigator = (ids, anchorRows, navigator)
        return navigator
    }

    private func updateCurrentIndex(_ geometry: GhosttyScrollbarSnapshot) {
        guard hasResolvedAnchors, geometry.revision == resolvedRevision else { return }
        let next = navigator.currentIndex(
            viewportTop: Int(clamping: geometry.offset),
            viewportRows: Int(clamping: geometry.len),
            isAtBottom: geometry.isAtBottom
        )
        if next != currentIndex { currentIndex = next }
    }

    /// Whether entry `index` has a known scrollback row.
    func isJumpable(_ index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        return anchorRows[entries[index].id] != nil
    }

    // MARK: - Navigation

    /// Scrolls so the prompt of entry `index` sits at the top of the viewport.
    ///
    /// - Returns: `false`, without scrolling, when the prompt is not in
    ///   scrollback or the terminal changed underneath the jump.
    @discardableResult
    func jump(toEntryAt index: Int) async -> Bool {
        guard entries.indices.contains(index) else { return false }
        return await jump(toEntryID: entries[index].id)
    }

    /// Scrolls so the prompt of entry `id` sits at the top of the viewport.
    ///
    /// Streaming output at the scrollback limit renumbers rows between the
    /// read and the scroll; the jump re-reads rows once when that happens.
    @discardableResult
    func jump(toEntryID id: String) async -> Bool {
        for attempt in 0..<2 {
            let fresh = attempt == 0 ? await ensureFreshAnchors() : await resolveAnchors()
            guard fresh, !Task.isCancelled,
                  let index = entries.firstIndex(where: { $0.id == id }),
                  let row = anchorRows[id] else {
                return false
            }
            if scroll(toPromptRow: row) {
                currentIndex = index
                return true
            }
        }
        return false
    }

    /// Jumps to the previous turn (or the start of the current one when its
    /// prompt has scrolled off the top).
    @discardableResult
    func jumpToPreviousTurn() async -> Bool {
        guard isVisible, await ensureFreshAnchors(), let geometry = lastGeometry else { return false }
        guard let target = navigator.previousTarget(
            viewportTop: Int(clamping: geometry.offset),
            viewportRows: Int(clamping: geometry.len),
            isAtBottom: geometry.isAtBottom
        ) else { return false }
        return await jump(toEntryAt: target)
    }

    /// Jumps to the next turn, or back to the live bottom after the last one.
    @discardableResult
    func jumpToNextTurn() async -> Bool {
        guard isVisible, await ensureFreshAnchors(), let geometry = lastGeometry else { return false }
        if let target = navigator.nextTarget(
            viewportTop: Int(clamping: geometry.offset),
            viewportRows: Int(clamping: geometry.len),
            isAtBottom: geometry.isAtBottom
        ) {
            return await jump(toEntryAt: target)
        }
        return scrollToBottom()
    }

    private func ensureFreshAnchors() async -> Bool {
        guard let geometry = viewport?.agentTurnRailGeometry() else { return false }
        let snapshot = GhosttyScrollbarSnapshot(geometry)
        lastGeometry = snapshot
        if hasResolvedAnchors,
           snapshot.revision == resolvedRevision,
           resolvedEntryIDs == entries.map(\.id) {
            return true
        }
        return await resolveAnchors()
    }

    private func scroll(toPromptRow row: Int) -> Bool {
        guard let viewport, let geometry = viewport.agentTurnRailGeometry() else { return false }
        guard geometry.rowSpaceRevision == resolvedRevision else { return false }
        let total = Int(clamping: geometry.scrollbar.total)
        let length = Int(clamping: geometry.scrollbar.len)
        let lastTopRow = max(0, total - length)
        // One row of context above the prompt.
        let target = min(max(row - 1, 0), lastTopRow)
        return viewport.agentTurnRailScroll(
            toRow: target,
            revision: geometry.rowSpaceRevision,
            isAtBottom: target >= lastTopRow
        )
    }

    private func scrollToBottom() -> Bool {
        guard let viewport, let geometry = viewport.agentTurnRailGeometry() else { return false }
        let total = Int(clamping: geometry.scrollbar.total)
        let length = Int(clamping: geometry.scrollbar.len)
        let lastTopRow = max(0, total - length)
        guard Int(clamping: geometry.scrollbar.offset) < lastTopRow else { return false }
        return viewport.agentTurnRailScroll(
            toRow: lastTopRow,
            revision: geometry.rowSpaceRevision,
            isAtBottom: true
        )
    }
}

/// Plain copy of the scrollbar geometry the model compares across updates.
struct GhosttyScrollbarSnapshot: Equatable {
    let total: UInt64
    let offset: UInt64
    let len: UInt64
    let revision: UInt64

    /// Whether the viewport shows the newest rows.
    var isAtBottom: Bool {
        offset + len >= total
    }

    init(_ geometry: NotificationScrollRestoreGeometry) {
        total = geometry.scrollbar.total
        offset = geometry.scrollbar.offset
        len = geometry.scrollbar.len
        revision = geometry.rowSpaceRevision
    }
}
