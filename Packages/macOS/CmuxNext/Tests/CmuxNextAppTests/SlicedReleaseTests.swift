import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextInput
import CmuxNextMemory
import Testing

/// Memory pressure releases the terminal warm set and the parked workspaces through the app's memory
/// coordinator, one surface close or one workspace teardown per release slice, on frames after the
/// pressure event (p07-memory-096). Before, `memoryPressureDidChange` closed every surface over the
/// smaller budget and tore down every parked workspace of every window in the event's turn.
@MainActor @Suite(.serialized)
struct SlicedReleaseTests {
    @Test func criticalReleasesOneSurfaceOrWorkspacePerSlice() {
        let rig = SlicedReleaseRig(warm: 30, windows: [(onScreen: true, parked: 50), (false, 50), (false, 50)])
        rig.kernel.send(.critical)
        #expect(rig.released == 0, "nothing is released in the pressure event's turn")

        let perFrame = rig.drain()

        #expect(rig.warm.closes == 30)
        #expect(rig.parked.teardowns == 150)
        #expect(perFrame.allSatisfy { $0 <= 1 }, "a slice released \(perFrame.max() ?? 0) items")
        // One slice per item, plus one per consumer that finds itself within its limit.
        #expect(perFrame.count <= 180 + 2, "the release took \(perFrame.count) slices")
        #expect(rig.slicer.frameDurations.allSatisfy { $0 <= .milliseconds(4) },
                "a release frame took \(rig.slicer.frameDurations.max() ?? .zero)")
        #expect(rig.cache.ledger.capacity == 0)
        #expect(rig.warmKeys.allSatisfy { !rig.cache.ledger.isRetained($0) })
        #expect(rig.windows.allSatisfy { $0.parked.isEmpty })
    }

    /// The warm set closes its surfaces before any parked workspace goes (lossless before lossy), and
    /// the parked workspaces of off-screen windows go before those of the window on screen, least
    /// recently shown first.
    @Test func hiddenGoesBeforeVisibleAdjacent() {
        let rig = SlicedReleaseRig(warm: 3, windows: [(onScreen: true, parked: 2), (false, 2), (false, 2)])
        rig.kernel.send(.critical)
        rig.drain()

        #expect(rig.order == ["warm", "warm", "warm", "w1-0", "w1-1", "w2-0", "w2-1", "w0-0", "w0-1"])
    }

    /// A workspace shown while the release runs is no longer parked and stays.
    @Test func aWorkspaceShownMidReleaseStays() {
        let rig = SlicedReleaseRig(warm: 0, windows: [(onScreen: false, parked: 4)])
        rig.kernel.send(.critical)
        rig.fireFrame()
        rig.windows[0].show("w0-3")
        rig.drain()

        #expect(rig.parked.teardowns == 3)
        #expect(!rig.order.contains("w0-3"))
    }

    /// Warning shrinks the warm set to its warning budget one surface per slice and keeps every parked
    /// workspace; normal raises the budget at once with no release.
    @Test func warningShrinksTheWarmSetSlicedAndKeepsParkedWorkspaces() {
        let rig = SlicedReleaseRig(warm: 30, windows: [(onScreen: false, parked: 5)])
        rig.kernel.send(.warning)
        #expect(rig.cache.ledger.capacity == SlicedReleaseRig.normalCapacity, "nothing closes in the event's turn")

        let perFrame = rig.drain()

        #expect(rig.warm.closes == 30 - SlicedReleaseRig.warningCapacity)
        #expect(perFrame.allSatisfy { $0 <= 1 })
        #expect(rig.parked.teardowns == 0)
        #expect(rig.cache.warmBudget.terminalCapacity == SlicedReleaseRig.warningCapacity)

        rig.kernel.send(.normal)
        #expect(!rig.slicer.hasPendingSlice)
        #expect(rig.cache.ledger.capacity == SlicedReleaseRig.normalCapacity)
        #expect(rig.cache.warmBudget.terminalCapacity == SlicedReleaseRig.normalCapacity)
    }

    /// Critical then normal before the next frame releases nothing.
    @Test func criticalThenNormalInOneTurnReleasesNothing() {
        let rig = SlicedReleaseRig(warm: 30, windows: [(onScreen: false, parked: 10)])
        rig.kernel.send(.critical)
        rig.kernel.send(.normal)
        rig.drain()

        #expect(rig.released == 0)
        #expect(rig.cache.ledger.capacity == SlicedReleaseRig.normalCapacity)
    }
}

/// A memory coordinator on a manual kernel source, fake frames and a fake clock, with a real cache's
/// warm set of hidden surfaces and fake windows of parked workspaces.
@MainActor
private final class SlicedReleaseRig {
    static let normalCapacity = 30
    static let warningCapacity = 6
    /// What one parked workspace teardown costs on the fake clock.
    static let teardownCost: Duration = .milliseconds(1)

    let clock: SliceClock
    let slicer: FrameSlices
    let kernel: ManualMemoryPressureSource
    let pressure: MemoryPressureEvents
    let coordinator: MemoryCoordinator
    let cache: TabContentCache
    let warm: WarmSetRelease
    let parked: ParkedWorkspaceRelease
    let windows: [FakeParkedWindow]
    let warmKeys: [String]
    /// The ledger keys owners by object identity: the owners live as long as the rig.
    private let owners: [Owner]
    /// Every item released, in order: `warm` for a surface, the id of a workspace.
    private(set) var order: [String] = []

    init(warm count: Int, windows layout: [(onScreen: Bool, parked: Int)]) {
        let clock = SliceClock()
        let kernel = ManualMemoryPressureSource()
        let slicer = FrameSlices(clock: clock)
        let pressure = MemoryPressureEvents(source: kernel)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slicer, clock: clock)
        let cache = TabContentCache(
            daemon: DaemonService(),
            cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap()),
            fileInput: NoFileInput())
        cache.ledger = SurfaceLedger(capacity: Self.normalCapacity)
        let keys = (0..<count).map { "warm-\($0)" }
        let owners = keys.map { _ in Owner() }
        for (key, owner) in zip(keys, owners) {
            _ = cache.ledger.present(key, by: ObjectIdentifier(owner), presence: .hidden)
        }
        var serial: UInt64 = 0
        var windows: [FakeParkedWindow] = []
        for (window, spec) in layout.enumerated() {
            var serials: [String: UInt64] = [:]
            for index in 0..<spec.parked {
                serial += 1
                serials["w\(window)-\(index)"] = serial
            }
            windows.append(FakeParkedWindow(onScreen: spec.onScreen, parked: serials))
        }
        let warm = WarmSetRelease(host: cache, registry: coordinator) { level in
            switch level {
            case .normal: Self.normalCapacity
            case .warning: Self.warningCapacity
            case .critical: 0
            }
        }
        cache.warmSetRelease = warm
        let hosts: [any ParkedWorkspaceHost] = windows
        self.clock = clock
        self.kernel = kernel
        self.slicer = slicer
        self.pressure = pressure
        self.coordinator = coordinator
        self.cache = cache
        self.warm = warm
        parked = ParkedWorkspaceRelease(hosts: { hosts }, registry: coordinator)
        self.windows = windows
        warmKeys = keys
        self.owners = owners
        for window in windows {
            window.onRelease = { [weak self] id in
                clock.advance(by: Self.teardownCost)
                self?.order.append(id)
            }
        }
    }

    /// Surfaces closed plus workspaces torn down so far.
    var released: Int { warm.closes + parked.teardowns }

    /// Fires one frame; returns how many items it released, or nil when no slice was asked for.
    @discardableResult
    func fireFrame() -> Int? {
        let before = released
        let closes = warm.closes
        guard slicer.fireFrame() else { return nil }
        order += Array(repeating: "warm", count: warm.closes - closes)
        return released - before
    }

    /// Fires frames until none is asked for; returns what each released.
    @discardableResult
    func drain(limit: Int = 10_000) -> [Int] {
        var perFrame: [Int] = []
        while perFrame.count < limit, let count = fireFrame() { perFrame.append(count) }
        return perFrame
    }
}

private final class Owner {}

/// One window of parked workspaces by park serial.
@MainActor
private final class FakeParkedWindow: ParkedWorkspaceHost {
    let showsOnScreen: Bool
    private(set) var parked: [String: UInt64]
    var onRelease: (String) -> Void = { _ in }

    init(onScreen: Bool, parked: [String: UInt64]) {
        showsOnScreen = onScreen
        self.parked = parked
    }

    var oldestReleasableParked: (id: String, serial: UInt64)? {
        parked.min { $0.value < $1.value }.map { (id: $0.key, serial: $0.value) }
    }

    func releaseParked(_ id: String) {
        guard parked.removeValue(forKey: id) != nil else { return }
        onRelease(id)
    }

    /// The person switches to `id`: it shows and is no longer parked.
    func show(_ id: String) {
        parked[id] = nil
    }
}

/// A clock whose time moves only when the test's work advances it.
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

    // Advanced and read on main; Clock is Sendable.
    private let offset = Mutex<Duration>(.zero)

    var now: Instant { Instant(offset: offset.withLock { $0 }) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func advance(by duration: Duration) {
        offset.withLock { $0 += duration }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw SleepError.notSupported
    }
}

/// Release frames the test fires; records the clock time each took (the main frame budget's view).
@MainActor
private final class FrameSlices: MemoryReleaseSlicer {
    private var pending: [@MainActor () -> Void] = []
    private let clock: SliceClock
    private(set) var frameDurations: [Duration] = []

    init(clock: SliceClock) {
        self.clock = clock
    }

    var hasPendingSlice: Bool { !pending.isEmpty }

    func scheduleSlice(_ slice: @escaping @MainActor () -> Void) {
        pending.append(slice)
    }

    /// Runs the slices asked for before this call (one frame); false when none was.
    func fireFrame() -> Bool {
        let slices = pending
        pending = []
        guard !slices.isEmpty else { return false }
        let start = clock.now
        for slice in slices { slice() }
        frameDurations.append(start.duration(to: clock.now))
        return true
    }
}
