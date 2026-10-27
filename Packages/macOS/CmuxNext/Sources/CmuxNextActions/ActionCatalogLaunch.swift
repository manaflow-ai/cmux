import CmuxNextCompat
import CmuxNextSignposts
import Dispatch
import os

/// What the main thread's read of the action catalog for the registry cost at launch: `debug.startup`'s
/// `action_catalog_main_wait_ms` is ``waitMilliseconds``.
public nonisolated struct ActionCatalogMainAccess: Sendable, Equatable {
    /// Who had built the catalog when the main thread read it.
    public nonisolated enum Outcome: UInt64, Sendable, CaseIterable {
        /// The launch warm-up thread had finished the build: the read cost nothing.
        case ready = 1
        /// The launch warm-up thread was still building: the main thread waited for the rest of that build.
        case waited = 2
        /// No build had started: the main thread built the catalog itself.
        case builtOnMain = 3

        /// The value of the read's signpost `outcome=` field.
        public var name: String {
            switch self {
            case .ready: "ready"
            case .waited: "waited"
            case .builtOnMain: "built_on_main"
            }
        }
    }

    /// Who had built the catalog.
    public let outcome: Outcome
    /// The main thread's time inside the read, in microseconds.
    public let microseconds: UInt64

    /// ``microseconds`` in milliseconds.
    public var milliseconds: Double { Double(microseconds) / 1_000 }

    /// The part of ``microseconds`` the main thread spent waiting for another thread's build; 0 unless
    /// ``Outcome/waited`` (a build on main is main-thread work, not a wait).
    public var waitMicroseconds: UInt64 { outcome == .waited ? microseconds : 0 }

    /// ``waitMicroseconds`` in milliseconds: `action_catalog_main_wait_ms`.
    public var waitMilliseconds: Double { Double(waitMicroseconds) / 1_000 }

    /// A recorded read.
    public init(outcome: Outcome, microseconds: UInt64) {
        self.outcome = outcome
        self.microseconds = microseconds
    }
}

/// The launch's build of ``ActionCatalog/all``: the warm-up thread runs ``build()`` at the top of `main`,
/// and the registry takes ``descriptors()`` on the main thread before the first window.
///
/// The catalog is one `swift_once` global: the first reader builds it, any other reader waits for that
/// build, and with no build started the main thread builds it itself (Chromium's
/// `base/lazy_instance_helpers.cc` has the same contract). The registry's read is a signpost interval
/// (`action_catalog.first_main_access`, category `launch`) and is recorded as ``mainAccess``, so a launch
/// shows whether the main thread waited, the way Chromium's `base/threading/scoped_blocking_call.h` makes a
/// UI-thread wait visible. Lock-free: two atomics.
///
/// ```swift
/// let catalog = ActionCatalogLaunch()
/// Thread { catalog.build() }.start()                      // launch warm-up thread
/// let registry = ActionRegistry.standard(launch: catalog, runTiming: timing, mainWork: mainWork)   // main
/// catalog.mainAccess?.waitMilliseconds                    // 0 when the build ended first
/// ```
public nonisolated final class ActionCatalogLaunch: Sendable {
    private nonisolated enum Phase: Int {
        case notStarted = 0, building, built
    }

    private static let intervalName: StaticString = "action_catalog.first_main_access"

    private let phase = Atomic<Int>(Phase.notStarted.rawValue)
    /// The recorded read: microseconds << 2 | outcome; 0 until the main thread's read.
    private let access = Atomic<UInt64>(0)
    private let read: @Sendable () -> [ActionDescriptor]
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let signposter = OSSignposter(subsystem: SignpostCategory.subsystem, category: SignpostCategory.launch.rawValue)

    /// The build of the app's catalog.
    public convenience init() {
        self.init(read: { ActionCatalog.all }, uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
    }

    /// - Parameters:
    ///   - read: Reads the catalog (``ActionCatalog/all``; tests pass their own).
    ///   - uptimeNanoseconds: The clock the main thread's read is timed with.
    init(read: @escaping @Sendable () -> [ActionDescriptor], uptimeNanoseconds: @escaping @Sendable () -> UInt64) {
        self.read = read
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    /// Builds the catalog on the calling thread (the launch warm-up thread).
    public func build() {
        buildBegan()
        _ = read()
        buildEnded()
    }

    func buildBegan() {
        phase.store(Phase.building.rawValue, ordering: .releasing)
    }

    func buildEnded() {
        phase.store(Phase.built.rawValue, ordering: .releasing)
    }

    /// The catalog, for the registry; the first read is timed, signposted and recorded as ``mainAccess``.
    ///
    /// A ``build()`` that has entered the read but not yet marked itself is recorded as
    /// ``ActionCatalogMainAccess/Outcome/builtOnMain``, with the time of the wait.
    @MainActor
    public func descriptors() -> [ActionDescriptor] {
        guard access.load(ordering: .relaxed) == 0 else { return read() }
        let phaseAtRead = Phase(rawValue: phase.load(ordering: .acquiring)) ?? .notStarted
        let interval = signposter.beginInterval(Self.intervalName, id: signposter.makeSignpostID())
        let start = uptimeNanoseconds()
        let descriptors = read()
        let microseconds = (uptimeNanoseconds() &- start) / 1_000
        let outcome: ActionCatalogMainAccess.Outcome = switch phaseAtRead {
        case .built: .ready
        case .building: .waited
        case .notStarted: .builtOnMain
        }
        access.store(microseconds << 2 | outcome.rawValue, ordering: .relaxed)
        signposter.endInterval(Self.intervalName, interval, "outcome=\(outcome.name, privacy: .public) us=\(microseconds, privacy: .public)")
        return descriptors
    }

    /// The main thread's first ``descriptors()`` read, once it happened.
    public var mainAccess: ActionCatalogMainAccess? {
        let raw = access.load(ordering: .relaxed)
        guard let outcome = ActionCatalogMainAccess.Outcome(rawValue: raw & 0b11) else { return nil }
        return ActionCatalogMainAccess(outcome: outcome, microseconds: raw >> 2)
    }
}
