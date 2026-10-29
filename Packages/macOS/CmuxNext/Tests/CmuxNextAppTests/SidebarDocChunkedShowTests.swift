import CmuxNextWakeups
import Foundation
@testable import CmuxNextSidebar
import Testing

/// `SidebarDocStore.show` in chunks (feature `sidebarDocChunkedShow`): a show of 400 rows that no
/// person's change asked for is built as visible tasks on the main-thread scheduler that stop when
/// `MainFrameBudget.shouldYield()` says so, keep to the visible share of each frame, and end with the same projection a
/// show at once makes. A person's change shows at once.
@MainActor @Suite(.serialized) struct SidebarDocChunkedShowTests {
    typealias Fixture = SidebarDocReorderProjectionCostTests

    /// While a person's key stays pending, every task of the show runs one unit and yields: the reducer's `view` call,
    /// then one chunk of 32 rows per task (13 for 408 rows), then the assembly. `shown` keeps the old projection until
    /// the assembly, and the show's `then` gets the new one once.
    @Test func aShowOf400RowsYieldsAfterEachChunkWhileAKeyIsPending() async throws {
        let store = try await Fixture.loaded()
        let clock = ChunkClock()
        let input = ChunkInput()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in ChunkLink() }
        let keeper = ChunkLinkKeeper(on: work)
        store.showInChunks(on: work)
        let live = Fixture.placed.map(Fixture.ref)
        var told: [SidebarDocProjection?] = []
        input.pending = true
        store.show(live: live) { told.append($0) }
        #expect(store.shown == nil && told.isEmpty, "a chunked show built its projection inline")
        var frames = 0
        while told.isEmpty, frames < 200 { Self.fire(work, clock, &frames) }
        let chunks = (Fixture.placed.count + Fixture.groups + 31) / 32
        #expect(work.budget.stats.tasks[0] == 1 + chunks + 1, "the view call, each chunk of 32 rows and the assembly are one task each")
        #expect(told.count == 1)
        #expect(told.first.flatMap { $0 } == store.shown)
        #expect(store.shown?.machines[Fixture.session]?.count == Fixture.loose + Fixture.groups)
        Fixture.expectMatchesFreshProjection(store, live: live, "after the chunked show")
        keeper.stop()
    }

    /// On a test clock that each step moves by its cost (the `view` call 0.5 ms + 4 us a row, 20 us a row taken, 0.5 ms
    /// for the assembly), no frame spends more than the visible share on the show of 400 rows, which takes several
    /// frames; a show the memo answers then shows at once.
    @Test func aShowOf400RowsNeverExceedsTheVisibleShareOfAFrame() async throws {
        let store = try await Fixture.loaded()
        let clock = ChunkClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in ChunkLink() }
        let keeper = ChunkLinkKeeper(on: work)
        let steps = ChunkSteps()
        store.showInChunks(on: work) { step in
            steps.all.append(step)
            switch step {
            case .view(let rows): clock.advance(ms: 0.5 + Double(rows) * 0.004)
            case .rows(let count): clock.advance(ms: Double(count) * 0.02)
            case .assembly: clock.advance(ms: 0.5)
            }
        }
        let live = Fixture.placed.map(Fixture.ref)
        var told = 0
        store.show(live: live) { _ in told += 1 }
        var frames = 0
        while told == 0, frames < 200 { Self.fire(work, clock, &frames) }
        Self.fire(work, clock, &frames) // rolls the last frame into the stats
        #expect(told == 1)
        #expect(steps.all.first == .view(rows: Fixture.placed.count + Fixture.groups) && steps.all.last == .assembly)
        #expect(work.budget.stats.tasks[0] >= 5, "the show of 400 rows fit in fewer frames than its cost needs")
        #expect(work.budget.stats.maxFrameNanos[0] <= MainFrameBudget.nanos(work.budget.budgets.visible),
                "a frame spent more than the visible share on the show")
        Fixture.expectMatchesFreshProjection(store, live: live, "after the chunked show")

        let tasks = work.budget.stats.tasks[0]
        store.show(live: live) { _ in told += 1 }
        #expect(told == 2, "a show the memo answers waited for a task")
        #expect(work.budget.stats.tasks[0] == tasks)
        keeper.stop()
    }

    /// While a key is pending, the show of a person's own move (the sidebar's drop runs outside any cause scope) lands
    /// in the turn that asks for it, with no task posted; the show of a move automation sent is built in chunks.
    @Test func aPersonsChangeShowsInTheTurnAndAnAutomationChangeIsChunked() async throws {
        let store = try await Fixture.loaded()
        let live = Fixture.placed.map(Fixture.ref)
        store.show(live: live)
        let clock = ChunkClock()
        let input = ChunkInput()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in ChunkLink() }
        let keeper = ChunkLinkKeeper(on: work)
        store.showInChunks(on: work)
        input.pending = true

        let unmoved = store.version
        store.move(["w_l5"], to: SidebarDocTarget(section: Fixture.section, after: "w_l10"), title: "Move")
        try #require(store.version > unmoved, "the reducer refused the person's move")
        var told = 0
        store.show(live: live) { _ in told += 1 }
        #expect(told == 1 && store.shownVersion == store.version, "a person's change waited for a chunked build")
        #expect(work.postedCount(.visible) == 0, "a person's change was posted as visible work")
        Fixture.expectMatchesFreshProjection(store, live: live, "after the person's move")

        let shownBefore = store.shownVersion
        work.causes.withCause(.automation) {
            store.move(["w_l6"], to: SidebarDocTarget(section: Fixture.section, after: "w_l11"), title: "Move")
        }
        try #require(store.version > shownBefore, "the reducer refused the automation's move")
        store.show(live: live) { _ in told += 1 }
        #expect(told == 1 && store.shownVersion == shownBefore, "an automation change was built inline")
        #expect(work.postedCount(.visible) == 1)
        var frames = 0
        while told == 1, frames < 200 { Self.fire(work, clock, &frames) }
        #expect(told == 2 && store.shownVersion == store.version)
        Fixture.expectMatchesFreshProjection(store, live: live, "after the automation's move")
        keeper.stop()
    }

    /// A workspace of a connected other machine that is placed, then leaves the live set while a chunked build of an
    /// older document is in progress, is closed there: the asks between the two builds are skipped, so the close reads
    /// the confirmed document, not only the projection shown last.
    @Test func aRemoteWorkspacePlacedAndClosedDuringABuildIsClosed() async throws {
        let remote = ChunkRemote(document: Fixture.document)
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        let placed = Fixture.placed.map(Fixture.ref)
        let added = Fixture.ref("new-w")
        let remotes: Set<String> = [Fixture.session] // the machine counts as a connected other machine
        store.show(live: placed + [added], connectedRemotes: remotes)
        #expect(store.shown?.unplaced == [added])
        let clock = ChunkClock()
        let input = ChunkInput()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in ChunkLink() }
        let keeper = ChunkLinkKeeper(on: work)
        store.showInChunks(on: work)
        input.pending = true

        // A batch that places nothing new: build A starts over a document where the workspace is not placed.
        store.receive(batch: Self.batch(revision: 2, item: "w_l0", Fixture.workspaceItem("l0", order: 0)))
        store.show(live: placed + [added], connectedRemotes: remotes)
        var frames = 0
        while store.showChunks?.build == nil, frames < 50 { Self.fire(work, clock, &frames) }
        try #require(store.showChunks?.build != nil, "build A did not start")
        // The workspace is placed (ask B), then leaves the live set while its machine stays connected (ask C replaces B).
        store.receive(batch: Self.batch(revision: 3, item: "w_new-w", Fixture.workspaceItem("new-w", order: 60)))
        try #require(store.records.item(for: added) != nil, "the batch did not place the workspace")
        store.show(live: placed + [added], connectedRemotes: remotes)
        var shownC = false
        store.show(live: placed, connectedRemotes: remotes) { _ in shownC = true }
        while !shownC, frames < 400 { Self.fire(work, clock, &frames) }
        try #require(shownC, "ask C never showed")
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { remote.closed.contains(added) }
        #expect(remote.closed == [added], "the store never closed the workspace placed and closed during the build")
        keeper.stop()
    }

    /// Fires the next frame, 17 ms after the last one.
    private static func fire(_ work: MainWorkScheduler, _ clock: ChunkClock, _ frames: inout Int) {
        frames += 1
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: Double(frames), refreshInterval: 1.0 / 60)
    }

    /// One echoed batch at document revision `revision` that upserts item `id` (JSON `value`).
    private static func batch(revision: Int, item id: String, _ value: String) -> Data {
        let change = #"{"kind": "state_upsert", "resource": "sidebar_item", "id": "\#(id)", "value": \#(value)}"#
        return Data(#"{"revision": "\#(revision)", "changes": [\#(change)]}"#.utf8)
    }
}

/// A frame-class client that keeps the scheduler's fake link up, so posts wait for hand-fired frames.
@MainActor
private final class ChunkLinkKeeper {
    private let client: FrameClient

    init(on work: MainWorkScheduler) {
        client = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        client.activate()
    }

    func stop() { client.deactivate() }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class ChunkClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

/// The steps of a build, in order.
@MainActor
private final class ChunkSteps {
    var all: [SidebarDocShowChunks.Step] = []
}

@MainActor
private final class ChunkInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class ChunkLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// A daemon that serves the document and records each workspace a `sidebar.apply` closes; other changes fail.
@MainActor
private final class ChunkRemote: SidebarDocRemote {
    let document: Data
    private(set) var closed: [SidebarDocWorkspaceRef] = []

    init(document: Data) { self.document = document }

    var isAvailable: Bool { true }
    func get() async throws -> Data { document }
    func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { throw CancellationError() }
    func pin(_ items: [String], key: String) async throws -> SidebarDocReply { throw CancellationError() }
    func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { throw CancellationError() }
    func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { throw CancellationError() }

    func apply(ops: Data, key: String) async throws -> SidebarDocReply {
        let decoded = try JSONDecoder().decode([ChunkOp].self, from: ops)
        closed += decoded.filter { $0.op == "close" }.flatMap { $0.refs ?? [] }
            .map { SidebarDocWorkspaceRef(sessionID: $0.sessionID, workspaceID: $0.workspaceID) }
        return SidebarDocReply(revision: nil, inverse: Data("[]".utf8))
    }
}

/// The part of a `sidebar.apply` op a `close` reads.
private nonisolated struct ChunkOp: Decodable {
    struct Ref: Decodable {
        var sessionID: String
        var workspaceID: String

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case workspaceID = "workspace_id"
        }
    }

    var op: String
    var refs: [Ref]?
}
