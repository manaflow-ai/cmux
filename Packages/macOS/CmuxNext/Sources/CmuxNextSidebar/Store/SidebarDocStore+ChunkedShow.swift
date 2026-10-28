public import CmuxNextWakeups

/// A chunked `SidebarDocStore.show` (feature `sidebarDocChunkedShow`): the projection of a large
/// document that no person's change asked for is built a few rows at a time as `visible` tasks on the app's main-thread
/// scheduler. Each task stops when ``MainFrameBudget/shouldYield()`` says so and posts the rest as a continuation, so
/// the show keeps to the visible share of each frame and a person's key goes first, as Blink splits long work with
/// `scheduler.yield()` (third_party/blink/renderer/modules/scheduler/dom_scheduler.cc).
///
/// A show of a person's change is never chunked: it builds at once, in the turn that asked for it, and drops any build
/// in progress (p06-scheduler.md rule 2: a person-visible change never waits behind visible work). Other builds never
/// restart: a show asked for while one builds waits for it, and only the newest such ask is kept, so a stream of
/// document changes still shows each finished build, and a built projection is never shown over a newer one.
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

    /// One unit of a build, between two ``MainFrameBudget/shouldYield()`` asks.
    enum Step: Equatable {
        /// The reducer's `view` call, which returned this many rows.
        case view(rows: Int)
        /// This many rows taken into the projection.
        case rows(Int)
        /// The projection assembled from every row and shown.
        case assembly
    }

    /// A queued task of the show.
    enum Queued {
        /// Starts a build of the newest ask (a plain visible post).
        case start
        /// Takes up the build that yielded (a continuation).
        case rest
    }

    /// The rows taken between two ``MainFrameBudget/shouldYield()`` asks: a few tens of microseconds, so the last
    /// chunk of a frame, whose cost the budget predicts from the one before it, keeps to the share.
    static let rowsPerChunk = 32

    let work: MainWorkScheduler
    let owner: MainTaskOwner
    /// Told after each step of a build (a test moves its clock by the step's cost); nil in the app.
    let stepped: (@MainActor (Step) -> Void)?
    /// The newest show asked for and not started.
    var asked: Ask?
    /// The build in progress; nil between builds.
    var build: Build?
    /// What the show's queued task is for: the start of a build, or the rest of one that yielded; nil: none is queued.
    var queued: Queued?
    /// The newest store `version` a person's change made: a show while `shownVersion` is behind it builds at once.
    var personVersion: UInt64 = 0

    init(work: MainWorkScheduler, stepped: (@MainActor (Step) -> Void)? = nil) {
        self.work = work
        self.stepped = stepped
        owner = work.board.owner("SidebarDocStore.show")
    }

    /// The store's `version` moved to `version`. It is a person's change when it was made under the person cause, or
    /// when it is a local intent (`localIntent`: a drop, a placement, a pin applied to the mirror) that no automation
    /// sent: the sidebar's own drag and menu paths run outside any cause scope.
    func noteChange(at version: UInt64, localIntent: Bool) {
        let cause = work.causes.currentCause
        if cause == .person || (localIntent && cause != .automation) { personVersion = version }
    }
}

extension SidebarDocStore {
    /// From now on, a `show` that must project the document for a change no person made builds the projection in
    /// chunks on `work` (``SidebarDocShowChunks``); `shown` keeps the last projection until the new one is built
    /// (`shownVersion` says it lags). A show of a person's change, or one the memo answers with no build in progress,
    /// still shows at once. The composition root calls it with feature `sidebarDocChunkedShow` on.
    public func showInChunks(on work: MainWorkScheduler) {
        showInChunks(on: work, stepped: nil)
    }

    /// ``showInChunks(on:)``, telling `stepped` after each step of a build (a test moves its clock by the step's cost).
    func showInChunks(on work: MainWorkScheduler, stepped: (@MainActor (SidebarDocShowChunks.Step) -> Void)?) {
        showChunks = SidebarDocShowChunks(work: work, stepped: stepped)
    }

    /// Takes `ask` for the chunked show; false when it shows now instead: it shows a person's change (a build in
    /// progress is dropped), or no build is in progress and it needs no projection (the memo answers it, or the
    /// document is not active).
    func queueShow(_ ask: SidebarDocShowChunks.Ask, on chunks: SidebarDocShowChunks) -> Bool {
        if chunks.personVersion > shownVersion {
            (chunks.build, chunks.asked) = (nil, nil)
            return false
        }
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

    /// Queues the show's next task, unless one is queued: the rest of a build that yielded at the front of the visible
    /// queue (`continuing`), or the start of a build behind the visible work posted before it.
    private func postShowChunk(_ chunks: SidebarDocShowChunks, continuing: Bool) {
        guard chunks.queued == nil else { return }
        chunks.queued = continuing ? SidebarDocShowChunks.Queued.rest : SidebarDocShowChunks.Queued.start
        let task: @MainActor () -> Void = { [weak self] in self?.runShowChunk() }
        if continuing {
            chunks.work.postContinuation(.visible, owner: chunks.owner, task)
        } else {
            chunks.work.post(.visible, owner: chunks.owner, task)
        }
    }

    /// One task of the chunked show: starts a build from the newest ask when none is in progress, takes rows until they
    /// end or the budget says to yield, and assembles and shows the projection once every row is in, unless the budget
    /// said to yield after the last chunk (the assembly is then the next task).
    private func runShowChunk() {
        guard let chunks = showChunks else { return }
        let ranAs = chunks.queued
        chunks.queued = nil
        // Taken out of `chunks`, so adding rows writes the builder in place (no copy-on-write of what it holds).
        var taken = chunks.build
        chunks.build = nil
        if taken == nil, ranAs == .rest {
            // A person's show dropped the build this continuation was for: a newer ask starts behind earlier visible work.
            chunks.work.budget.noteRanNothing()
            if chunks.asked != nil { postShowChunk(chunks, continuing: false) }
            return
        }
        // A build started here took the reducer's `view` call as this task's first step.
        let started = taken == nil
        if started { taken = startBuild(chunks) }
        guard var build = taken else { return }
        var yields = started && chunks.work.budget.shouldYield()
        while !yields, build.next < build.rows.count {
            let end = min(build.next + SidebarDocShowChunks.rowsPerChunk, build.rows.count)
            for row in build.rows[build.next..<end] { build.builder.add(row) }
            chunks.stepped?(.rows(end - build.next))
            build.next = end
            yields = chunks.work.budget.shouldYield()
        }
        guard !yields else {
            chunks.build = build
            return postShowChunk(chunks, continuing: true)
        }
        let projection = isActive ? build.builder.projection() : nil
        if let projection { projectionCache = SidebarDocProjectionCache(version: build.version, live: build.ask.live, projection: projection) }
        showProjection(projection, at: build.version, live: build.ask.live, connectedRemotes: build.ask.connectedRemotes)
        chunks.stepped?(.assembly)
        build.ask.then?(shown)
        if chunks.asked != nil { postShowChunk(chunks, continuing: false) }
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
        chunks.stepped?(.view(rows: rows.count))
        return SidebarDocShowChunks.Build(ask: ask, version: version, rows: rows,
                                          builder: SidebarDocProjection.Builder(records: records, revision: records.revision))
    }
}
