public import CmuxNextWakeups

/// A chunked `SidebarDocStore.show` (feature `sidebarDocChunkedShow`, p06-scheduler-200): the projection of a large
/// document is built a few rows at a time as `visible` tasks on the app's main-thread scheduler. Each task stops when
/// ``MainFrameBudget/shouldYield()`` says so and posts the rest as a continuation, so the show keeps to the visible
/// share of each frame and a person's key goes first, as Blink splits long work with `scheduler.yield()`
/// (third_party/blink/renderer/modules/scheduler/dom_scheduler.cc).
///
/// Builds never restart: a show asked for while one builds waits for it, and only the newest such ask is kept. So a
/// stream of document changes still shows each finished build, and a built projection is never shown over a newer one.
@MainActor
final class SidebarDocShowChunks {
    /// A show asked for: the live workspaces, the connected other machines, and who gets `shown` once it shows.
    struct Ask {
        var live: [SidebarDocWorkspaceRef]
        var connectedRemotes: Set<String>
        var then: (@MainActor (SidebarDocProjection?) -> Void)?
    }

    /// A projection in progress: the reducer's rows of the document at `version`, taken up to `next`.
    struct Build {
        var ask: Ask
        var version: UInt64
        var rows: [SidebarDocRow]
        var next = 0
        var builder: SidebarDocProjection.Builder
    }

    /// The rows taken between two ``MainFrameBudget/shouldYield()`` asks: a few tens of microseconds, so the last
    /// chunk of a frame, whose cost the budget predicts from the one before it, keeps to the share.
    static let rowsPerChunk = 32

    let work: MainWorkScheduler
    let owner: MainTaskOwner
    /// The newest show asked for and not started.
    var asked: Ask?
    /// The build in progress; nil between builds.
    var build: Build?
    /// A task of the show is queued.
    var queued = false

    init(work: MainWorkScheduler) {
        self.work = work
        owner = work.board.owner("SidebarDocStore.show")
    }
}

extension SidebarDocStore {
    /// From now on, a `show` that must project the document builds the projection in chunks on `work`
    /// (``SidebarDocShowChunks``); `shown` keeps the last projection until the new one is built (`shownVersion` says it
    /// lags). A show the memo answers, with no build in progress, still shows at once. The composition root calls it with
    /// feature `sidebarDocChunkedShow` on.
    public func showInChunks(on work: MainWorkScheduler) {
        showChunks = SidebarDocShowChunks(work: work)
    }

    /// Takes `ask` for the chunked show; false when it shows now instead: no build is in progress and it needs no
    /// projection (the memo answers it, or the document is not active).
    func queueShow(_ ask: SidebarDocShowChunks.Ask, on chunks: SidebarDocShowChunks) -> Bool {
        if chunks.build == nil, needsNoBuild(ask.live) {
            chunks.asked = nil
            return false
        }
        chunks.asked = ask
        if chunks.build == nil { postShowChunk(chunks, continuing: false) }
        return true
    }

    private func needsNoBuild(_ live: [SidebarDocWorkspaceRef]) -> Bool {
        !isActive || projectionCache?.answers(version: version, live: live) == true
    }

    /// Queues the show's next task, unless one is queued: the rest of a build at the front of the visible queue.
    private func postShowChunk(_ chunks: SidebarDocShowChunks, continuing: Bool) {
        guard !chunks.queued else { return }
        chunks.queued = true
        let task: @MainActor () -> Void = { [weak self] in self?.runShowChunk() }
        if continuing {
            chunks.work.postContinuation(.visible, owner: chunks.owner, task)
        } else {
            chunks.work.post(.visible, owner: chunks.owner, task)
        }
    }

    /// One task of the chunked show: starts a build from the newest ask when none is in progress, takes rows until they
    /// end or the budget says to yield, and shows the projection once every row is in.
    private func runShowChunk() {
        guard let chunks = showChunks else { return }
        chunks.queued = false
        // Taken out of `chunks`, so adding rows writes the builder in place (no copy-on-write of what it holds).
        var taken = chunks.build
        chunks.build = nil
        // A build started here took the reducer's `view` call as this task's first chunk.
        let started = taken == nil
        if started { taken = startBuild(chunks) }
        guard var build = taken else { return }
        var yields = started && chunks.work.budget.shouldYield()
        while !yields, build.next < build.rows.count {
            let end = min(build.next + SidebarDocShowChunks.rowsPerChunk, build.rows.count)
            for row in build.rows[build.next..<end] { build.builder.add(row) }
            build.next = end
            yields = build.next < build.rows.count && chunks.work.budget.shouldYield()
        }
        guard build.next == build.rows.count else {
            chunks.build = build
            return postShowChunk(chunks, continuing: true)
        }
        let projection = isActive ? build.builder.projection() : nil
        if let projection { projectionCache = SidebarDocProjectionCache(version: build.version, live: build.ask.live, projection: projection) }
        showProjection(projection, at: build.version, live: build.ask.live, connectedRemotes: build.ask.connectedRemotes)
        build.ask.then?(shown)
        if chunks.asked != nil { postShowChunk(chunks, continuing: true) }
    }

    /// The build of the newest ask: the reducer's rows of the document now (one `view` call). Nil when there is none, or
    /// when it needs no build now (it is shown in this task).
    private func startBuild(_ chunks: SidebarDocShowChunks) -> SidebarDocShowChunks.Build? {
        guard let ask = chunks.asked else {
            chunks.work.budget.noteRanNothing()
            return nil
        }
        chunks.asked = nil
        guard !needsNoBuild(ask.live), let rows = rows(SidebarViewRequest(live: ask.live)) else {
            showProjection(projection(live: ask.live), at: version, live: ask.live, connectedRemotes: ask.connectedRemotes)
            ask.then?(shown)
            return nil
        }
        return SidebarDocShowChunks.Build(ask: ask, version: version, rows: rows,
                                          builder: SidebarDocProjection.Builder(records: records, revision: records.revision))
    }
}
