import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextInput
import CmuxNextMemory
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// Memory pressure releases the terminal warm set and the parked workspaces through the app's memory
/// coordinator, one surface close and one workspace teardown per release slice, on frames after the
/// pressure event. Before, `memoryPressureDidChange` closed every surface over the
/// smaller budget and tore down every parked workspace of every window in the event's turn.
///
/// What a real close or teardown costs on the main thread is not measured here: the fake clock only
/// moves when a test moves it. The "no turn over 4 ms" clause rests on `bench_memory --pressure
/// critical` with a 150 workspace STRESS session on the fleet.
@MainActor @Suite(.serialized)
struct SlicedReleaseTests {
    @Test func criticalReleasesOneSurfaceAndOneWorkspacePerSlice() {
        let rig = SlicedReleaseRig(warm: 30, windows: [(onScreen: true, parked: 50), (false, 50), (false, 50)])
        rig.kernel.send(.critical)
        #expect(rig.released == 0, "nothing is released in the pressure event's turn")

        let frames = rig.drain()

        #expect(rig.warm.closes == 30)
        #expect(rig.parked.discardedCount == 150)
        #expect(frames.allSatisfy { $0.closes <= 1 }, "a slice closed \(frames.map { $0.closes }.max() ?? 0) surfaces")
        #expect(frames.allSatisfy { $0.teardowns <= 1 }, "a slice tore down \(frames.map { $0.teardowns }.max() ?? 0) workspaces")
        // The two release side by side: one slice per workspace, plus one that finds the release done.
        #expect(frames.count <= 150 + 1, "the release took \(frames.count) slices")
        #expect(rig.cache.ledger.capacity == 0)
        #expect(rig.warmKeys.allSatisfy { !rig.cache.ledger.isRetained($0) })
        #expect(rig.windows.allSatisfy { $0.parked.isEmpty })
    }

    /// A consumer ordered after the warm set (the browser's urgent discard pass) runs on the first
    /// release frame, not after the warm set's 30 single closes.
    @Test func theUrgentPassRunsOnTheFirstReleaseFrame() {
        let rig = SlicedReleaseRig(warm: 30, windows: [(onScreen: false, parked: 5)])
        rig.kernel.send(.critical)
        rig.drain()

        #expect(rig.urgent.passFrames == [1], "the urgent pass ran on frames \(rig.urgent.passFrames)")
        #expect(rig.order.prefix(2) == ["warm", "w0-0"], "the first frame did not close a surface, then tear down a workspace")
    }

    /// The parked workspaces of off-screen windows go before those of the window on screen, least
    /// recently shown first; in each frame the warm set (lossless) goes before the teardown (lossy).
    @Test func hiddenGoesBeforeVisibleAdjacent() {
        let rig = SlicedReleaseRig(warm: 3, windows: [(onScreen: true, parked: 2), (false, 2), (false, 2)])
        rig.kernel.send(.critical)
        rig.drain()

        #expect(rig.order.filter { $0 != "warm" } == ["w1-0", "w1-1", "w2-0", "w2-1", "w0-0", "w0-1"])
        #expect(rig.order.prefix(6) == ["warm", "w1-0", "warm", "w1-1", "warm", "w2-0"])
    }

    /// A workspace shown while the release runs is no longer parked and stays.
    @Test func aWorkspaceShownMidReleaseStays() {
        let rig = SlicedReleaseRig(warm: 0, windows: [(onScreen: false, parked: 4)])
        rig.kernel.send(.critical)
        rig.fireFrame()
        rig.windows[0].show("w0-3")
        rig.drain()

        #expect(rig.parked.discardedCount == 3)
        #expect(!rig.order.contains("w0-3"))
    }

    /// Warning scales the warm set by its limit, the Memory Saver mode's share of 50 % (medium: 25 %),
    /// one surface per slice, and keeps every parked workspace; a mode with a larger share raises it at
    /// once, and normal gives back the full capacity with no release.
    @Test func warningScalesTheWarmSetByItsLimitAndKeepsParkedWorkspaces() {
        let rig = SlicedReleaseRig(warm: 30, windows: [(onScreen: false, parked: 5)])
        rig.kernel.send(.warning)
        #expect(rig.cache.ledger.capacity == SlicedReleaseRig.normalCapacity, "nothing closes in the event's turn")
        let warning = rig.coordinator.limit(for: WarmSetRelease.memoryTraits)
        #expect(warning == MemoryLimit(percent: 25))
        #expect(rig.cache.warmBudget.terminalCapacity == warning.scale(SlicedReleaseRig.normalCapacity))

        let frames = rig.drain()

        #expect(rig.warm.closes == 30 - warning.scale(SlicedReleaseRig.normalCapacity))
        #expect(frames.allSatisfy { $0.closes <= 1 })
        #expect(rig.parked.discardedCount == 0)
        #expect(rig.cache.ledger.capacity == warning.scale(SlicedReleaseRig.normalCapacity))

        rig.coordinator.mode = .off
        let off = rig.coordinator.limit(for: WarmSetRelease.memoryTraits)
        #expect(rig.cache.ledger.capacity == off.scale(SlicedReleaseRig.normalCapacity), "the warm set did not follow its larger limit")

        rig.kernel.send(.normal)
        #expect(!rig.slicer.hasPendingSlice)
        #expect(rig.cache.ledger.capacity == SlicedReleaseRig.normalCapacity)
        #expect(rig.cache.warmBudget.terminalCapacity == SlicedReleaseRig.normalCapacity)
    }

    /// Surfaces hidden in the last 2 s are the warm set's working set (p07-memory.md section 3.A):
    /// critical closes the older ones and stops there.
    @Test func criticalKeepsTheSurfacesHiddenInTheLastTwoSeconds() {
        let rig = SlicedReleaseRig(warm: 10, windows: [])
        rig.clock.advance(by: .seconds(5))
        let recent = rig.hide(3)
        rig.clock.advance(by: .seconds(1))
        rig.kernel.send(.critical)
        let frames = rig.drain()

        #expect(rig.warm.closes == 10)
        #expect(recent.allSatisfy { rig.cache.ledger.isRetained($0) }, "a surface hidden a second ago closed")
        #expect(rig.cache.ledger.capacity == 3)
        #expect(frames.count == 11, "the working set did not end the release (\(frames.count) frames)")
    }

    /// Critical then normal before the next frame releases nothing.
    @Test func criticalThenNormalInOneTurnReleasesNothing() {
        let rig = SlicedReleaseRig(warm: 30, windows: [(onScreen: false, parked: 10)])
        rig.kernel.send(.critical)
        rig.kernel.send(.normal)
        rig.drain()

        #expect(rig.released == 0)
        #expect(rig.urgent.passFrames.isEmpty)
        #expect(rig.cache.ledger.capacity == SlicedReleaseRig.normalCapacity)
    }

    /// The warm set's release closes real terminals (`TerminalEntry`) at once, keeping no last picture.
    @Test func aReleasedSurfaceClosesAtOnceWithNoLastFrame() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let rig = SlicedReleaseRig(warm: 0, windows: [], cache: cache)
        var scripted: [ScriptedTerminalIO] = []
        defer { scripted.forEach { $0.finish() } }
        let keys = (1...3).map { "terminal-\($0)" }
        for (index, key) in keys.enumerated() {
            let io = ScriptedTerminalIO()
            scripted.append(io)
            cache.terminals[key] = try Self.entry(services, surface: UInt64(index + 1), io: io)
        }
        rig.hide(keys)
        rig.clock.advance(by: .seconds(3))
        let kept = cache.lastFrames.outcomes["kept"] ?? 0, atOnce = cache.lastFrames.outcomes["evicted_at_once"] ?? 0

        rig.kernel.send(.critical)
        let frames = rig.drain()

        #expect(frames.allSatisfy { $0.closes <= 1 })
        #expect(keys.allSatisfy { cache.terminals[$0] == nil }, "a hidden terminal stayed open at critical")
        #expect(keys.allSatisfy { cache.lastFrames[$0] == nil }, "a pressure close kept a last frame")
        #expect((cache.lastFrames.outcomes["evicted_at_once"] ?? 0) - atOnce == keys.count)
        #expect((cache.lastFrames.outcomes["kept"] ?? 0) == kept)
        withExtendedLifetime(services) {}
    }

    /// A terminal of the cache on a scripted IO, as `TabContentCache` makes one for a daemon tab.
    private static func entry(_ services: AppServices, surface: UInt64, io scripted: ScriptedTerminalIO) throws -> TerminalEntry {
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), title: "~"))
        let session = TerminalSession(io: scripted, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let attachment = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: nil, generation: nil)
        let io = DaemonTerminalIO(target: .init(attachment: attachment, initialSize: CellSize(cols: 80, rows: 24)), resizes: ResizeCoordinator(),
                                  visible: false, connection: { throw CancellationError() })
        return TerminalEntry(validity: "test", session: session, io: io, themeKey: TerminalThemeKey(machine: services.daemon.machineID, tab: tab),
                             store: services.daemon.store, surface: tab.surface, mainWork: services.mainWork)
    }
}

/// The production `WindowController` under the parked workspaces' release: the workspace under a top
/// page and the ones `sidebar.multiView` shows stay; the others go, least recently shown first.
@MainActor @Suite(.serialized)
struct SlicedReleaseWindowTests {
    /// A window over `k0`...`k3` that showed each, back on `k0`: `k1`, `k2`, `k3` are parked, `k1` the
    /// least recently shown.
    private static func window() async throws -> SpaceSwitchBench {
        try await SpaceSwitchBench(total: 4, spaces: 1, panes: true, parked: 4)
    }

    /// Tears down at critical pressure, slice by slice, what the app's parked budget gives up.
    private static func releaseAtCritical(_ bench: SpaceSwitchBench) -> [String] {
        let budget = bench.services.parkedWorkspaceBudget
        let before = Set(bench.controller.parked.keys)
        budget.updateMemoryLimit(.criticalThreshold)
        let slice = MemoryReleaseSlice(limit: .criticalThreshold) { false }
        var order: [String] = []
        var remaining = before
        for _ in 0..<before.count + 1 {
            let progress = budget.releaseMemory(within: slice)
            let gone = remaining.subtracting(bench.controller.parked.keys)
            #expect(gone.count <= 1, "one slice tore down \(gone.sorted())")
            order += gone.sorted()
            remaining.subtract(gone)
            if progress == .done { break }
        }
        return order
    }

    @Test func theWorkspaceUnderATopPageStays() async throws {
        let bench = try await Self.window()
        defer { bench.close() }
        #expect(Set(bench.controller.parked.keys) == ["k1", "k2", "k3"])
        bench.controller.parkContentForPage()
        #expect(bench.controller.parked["k0"] != nil, "the top page did not park the window's workspace")

        #expect(Self.releaseAtCritical(bench) == ["k1", "k2", "k3"])
        #expect(Set(bench.controller.parked.keys) == ["k0"], "the workspace under the top page went")
    }

    @Test func theWorkspacesMultiViewShowsStay() async throws {
        let bench = try await Self.window()
        defer { bench.close() }
        bench.state.viewSet = .split(stacked: false, first: .workspace("k0"), second: .workspace("k2"))
        #expect(bench.controller.keepsParkedWorkspace("k2"))

        #expect(Self.releaseAtCritical(bench) == ["k1", "k3"])
        #expect(Set(bench.controller.parked.keys) == ["k2"], "a workspace on screen beside the shown one went")
    }
}

/// A memory coordinator on a manual kernel source, fake frames and a fake clock, with a real cache's
/// warm set of hidden surfaces, a lossy urgent pass ordered after it, and the parked budget over fake
/// windows of parked workspaces.
@MainActor
private final class SlicedReleaseRig {
    static let normalCapacity = 30

    let clock: SliceClock
    let slicer: FrameSlices
    let kernel: ManualMemoryPressureSource
    let pressure: MemoryPressureEvents
    let coordinator: MemoryCoordinator
    let cache: TabContentCache
    let warm: WarmSetRelease
    let urgent: FakeUrgentPass
    let parked: ParkedWorkspaceBudget
    let windows: [FakeParkedWindow]
    private(set) var warmKeys: [String] = []
    /// The ledger keys' owners by object identity: the owners live as long as the rig.
    private var owners: [Owner] = []
    /// Every item released, in order: `warm` for a surface, the id of a workspace.
    private(set) var order: [String] = []
    /// Frames fired so far.
    private(set) var frames = 0

    init(warm count: Int, windows layout: [(onScreen: Bool, parked: Int)], cache given: TabContentCache? = nil) {
        let clock = SliceClock()
        let kernel = ManualMemoryPressureSource()
        let slicer = FrameSlices()
        let pressure = MemoryPressureEvents(source: kernel)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slicer, clock: clock)
        let cache = given ?? TabContentCache(
            daemon: DaemonService(),
            chromium: ChromiumEngineSlot(CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())),
            fileInput: NoFileInput(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        cache.ledger = SurfaceLedger(capacity: Self.normalCapacity) { clock.instant }
        self.clock = clock
        self.kernel = kernel
        self.slicer = slicer
        self.pressure = pressure
        self.coordinator = coordinator
        self.cache = cache
        let warm = WarmSetRelease(host: cache, normalCapacity: Self.normalCapacity, registry: coordinator)
        cache.warmSetRelease = warm
        self.warm = warm
        urgent = FakeUrgentPass(registry: coordinator)
        parked = ParkedWorkspaceBudget(capacity: nil, idleTimeout: nil, deadline: NoLook(), memory: coordinator)
        self.windows = layout.map { FakeParkedWindow(onScreen: $0.onScreen) }
        urgent.frame = { [unowned self] in self.frames }
        for window in self.windows {
            window.budget = parked
            window.onDiscard = { [unowned self] id in self.order.append(id) }
        }
        for (index, spec) in layout.enumerated() {
            for workspace in 0..<spec.parked { self.windows[index].park("w\(index)-\(workspace)") }
        }
        hide((0..<count).map { "warm-\($0)" })
        clock.advance(by: .seconds(3))  // out of the working set
    }

    /// Hides `count` new surfaces now; returns their keys.
    @discardableResult
    func hide(_ count: Int) -> [String] {
        let keys = (warmKeys.count..<warmKeys.count + count).map { "warm-\($0)" }
        hide(keys)
        return keys
    }

    /// Hides surfaces `keys` now, each under its own presenter.
    func hide(_ keys: [String]) {
        for key in keys {
            let owner = Owner()
            owners.append(owner)
            _ = cache.ledger.present(key, by: ObjectIdentifier(owner), presence: .hidden)
        }
        warmKeys += keys
    }

    /// Surfaces closed plus workspaces torn down so far.
    var released: Int { warm.closes + parked.discardedCount }

    /// Fires one frame; returns what it released, or nil when no slice was asked for.
    @discardableResult
    func fireFrame() -> (closes: Int, teardowns: Int)? {
        guard slicer.hasPendingSlice else { return nil }
        let closes = warm.closes, teardowns = parked.discardedCount, before = order.count
        frames += 1
        slicer.fireFrame()
        // The warm set releases first in a frame (lossless before lossy).
        order.insert(contentsOf: Array(repeating: "warm", count: warm.closes - closes), at: before)
        return (warm.closes - closes, parked.discardedCount - teardowns)
    }

    /// Fires frames until none is asked for; returns what each released.
    @discardableResult
    func drain(limit: Int = 10_000) -> [(closes: Int, teardowns: Int)] {
        var perFrame: [(closes: Int, teardowns: Int)] = []
        while perFrame.count < limit, let frame = fireFrame() { perFrame.append(frame) }
        return perFrame
    }
}

private final class Owner {}

/// A lossy consumer with the browser hibernation's traits: it acts once per critical limit, on the
/// release slice, as `BrowserHibernation`'s urgent discard pass.
@MainActor
private final class FakeUrgentPass: MemoryConsumer {
    static let traits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .reads, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .high, isStateful: false, supportsMemoryLimit: false)

    /// The frames its passes ran on.
    private(set) var passFrames: [Int] = []
    var frame: () -> Int = { 0 }
    private var registration: MemoryConsumerRegistration?

    init(registry: any MemoryConsumerRegistry) {
        registration = MemoryConsumerRegistration(name: "urgent-pass", traits: Self.traits, consumer: self, registry: registry)
    }

    func updateMemoryLimit(_ limit: MemoryLimit) {}

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        if slice.limit.isCritical { passFrames.append(frame()) }
        return .done
    }

    var memoryUsage: MemoryUsage? { nil }
}

/// One window of parked workspaces, parked in order.
@MainActor
private final class FakeParkedWindow: ParkedWorkspaceHolder {
    let showsOnScreen: Bool
    private(set) var parked: Set<String> = []
    weak var budget: ParkedWorkspaceBudget?
    var onDiscard: (String) -> Void = { _ in }

    init(onScreen: Bool) {
        showsOnScreen = onScreen
    }

    func park(_ id: String) {
        parked.insert(id)
        budget?.didPark(id, in: self)
    }

    /// The person switches to `id`: it shows and is no longer parked.
    func show(_ id: String) {
        parked.remove(id)
        budget?.forget(id, in: self)
    }

    func keepsParkedWorkspace(_ id: String) -> Bool { false }

    func discardParkedWorkspace(_ id: String) -> Bool {
        guard parked.remove(id) != nil else { return false }
        onDiscard(id)
        return true
    }
}

/// The parked budget's look deadline: with no budget and no timeout a park arms none.
@MainActor
private final class NoLook: ParkedWorkspaceDeadline {
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        Issue.record("a look was armed with no budget and no timeout")
    }

    func cancel() {}
}

/// A clock whose time moves only when the test moves it: the slices' budget and the warm set's hide
/// times.
private nonisolated final class SliceClock: Clock, Sendable {
    nonisolated struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    /// The release never sleeps; a sleep is a test failure.
    nonisolated enum SleepError: Error {
        case notSupported
    }

    private let base = ContinuousClock.now
    // Advanced and read on main; Clock is Sendable.
    private let offset = Mutex<Duration>(.zero)

    var now: Instant { Instant(offset: offset.withLock { $0 }) }
    var minimumResolution: Duration { .nanoseconds(1) }

    /// The same time as a `ContinuousClock` instant (the ledger's hide times).
    var instant: ContinuousClock.Instant { base.advanced(by: offset.withLock { $0 }) }

    func advance(by duration: Duration) {
        offset.withLock { $0 += duration }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw SleepError.notSupported
    }
}

/// Release frames the test fires.
@MainActor
private final class FrameSlices: MemoryReleaseSlicer {
    private var pending: [@MainActor () -> Void] = []

    var hasPendingSlice: Bool { !pending.isEmpty }

    func scheduleSlice(_ slice: @escaping @MainActor () -> Void) {
        pending.append(slice)
    }

    /// Runs the slices asked for before this call (one frame).
    func fireFrame() {
        let slices = pending
        pending = []
        for slice in slices { slice() }
    }
}
