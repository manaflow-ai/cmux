import CmuxNextCompat
import CmuxNextSignposts
import Dispatch

/// What the main thread's read of the action catalog for the registry cost at launch: `debug.startup`'s
/// `action_catalog_main_wait_ms` is ``waitMilliseconds``.
public nonisolated struct ActionCatalogMainAccess: Sendable, Equatable {
    /// Who had built the catalog when the main thread read it.
    public nonisolated enum Outcome: UInt64, Sendable, CaseIterable {
        /// The launch warm-up thread had finished the build: the read cost nothing.
        case ready = 1
        /// The launch warm-up thread had claimed the build and not finished it: the main thread's read lasted until
        /// the catalog was there.
        case waited = 2
        /// No build had started: the main thread built the catalog itself.
        case builtOnMain = 3

        /// The value of the read's signpost `outcome=` field (its ring `arg0` is the raw value).
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
/// The catalog is one `swift_once` global, so whoever reads it first builds it and any other reader waits for
/// that build. Who builds it is decided by one atomic claim before the read, the way Chromium's
/// `base/lazy_instance_helpers.cc` claims a lazy instance with a compare-and-swap: ``build()`` claims it for the
/// warm-up thread and skips the read when main already holds it; the registry's first read claims it for main
/// when no build has started (``ActionCatalogMainAccess/Outcome/builtOnMain``), and otherwise records the claim
/// it found: a finished build (``ActionCatalogMainAccess/Outcome/ready``) or one still running, whose rest main
/// waits for (``ActionCatalogMainAccess/Outcome/waited``). That read is the catalog's
/// `launch.action_catalog_first_main_access` interval and is recorded as ``mainAccess``, so a launch shows a
/// main-thread wait the way Chromium's `base/threading/scoped_blocking_call.h` does. Lock-free: two atomics.
///
/// ```swift
/// let catalog = ActionCatalogLaunch()
/// Thread { catalog.build() }.start()                      // launch warm-up thread
/// let registry = ActionRegistry.standard(launch: catalog, runTiming: timing, mainWork: mainWork)   // main
/// catalog.mainAccess?.waitMilliseconds                    // 0 when the build ended first
/// ```
public nonisolated final class ActionCatalogLaunch: Sendable {
    private nonisolated enum Phase: Int {
        /// Nobody has claimed the build.
        case notStarted = 0
        /// The warm-up thread claimed it and is reading the catalog.
        case building
        /// The warm-up thread's read returned.
        case built
        /// Main claimed it first and read the catalog itself; no other build runs.
        case claimedByMain
    }

    private let phase = Atomic<Int>(Phase.notStarted.rawValue)
    /// The recorded read: microseconds << 2 | outcome; 0 until the main thread's read.
    private let access = Atomic<UInt64>(0)
    private let read: @Sendable () -> [ActionDescriptor]
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let signposter: Signposter

    /// The build of the app's catalog.
    public convenience init() {
        self.init(read: { ActionCatalog.all }, uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
    }

    /// - Parameters:
    ///   - read: Reads the catalog (``ActionCatalog/all``; tests pass their own).
    ///   - uptimeNanoseconds: The clock the main thread's read is timed with.
    ///   - signposter: Emits the read's `launch.action_catalog_first_main_access` interval.
    init(read: @escaping @Sendable () -> [ActionDescriptor], uptimeNanoseconds: @escaping @Sendable () -> UInt64,
         signposter: Signposter = .launch) {
        self.read = read
        self.uptimeNanoseconds = uptimeNanoseconds
        self.signposter = signposter
    }

    /// Builds the catalog on the calling thread (the launch warm-up thread), unless main or an earlier
    /// ``build()`` already claimed it.
    public func build() {
        guard claimBuild() else { return }
        _ = read()
        phase.store(Phase.built.rawValue, ordering: .releasing)
    }

    /// Claims the build for the calling thread; false when it was already claimed.
    func claimBuild() -> Bool {
        phase.compareExchange(expected: Phase.notStarted.rawValue, desired: Phase.building.rawValue,
                              ordering: .acquiringAndReleasing).exchanged
    }

    /// The catalog, for the registry; the first read is timed, signposted and recorded as ``mainAccess``.
    @MainActor
    public func descriptors() -> [ActionDescriptor] {
        guard access.load(ordering: .relaxed) == 0 else { return read() }
        let claim = phase.compareExchange(expected: Phase.notStarted.rawValue, desired: Phase.claimedByMain.rawValue,
                                          ordering: .acquiringAndReleasing)
        let outcome: ActionCatalogMainAccess.Outcome = if claim.exchanged {
            .builtOnMain
        } else {
            Phase(rawValue: claim.original) == .built ? .ready : .waited
        }
        let name = SignpostName.launchActionCatalogFirstMainAccess
        let interval = signposter.begin(name, "outcome=\(outcome.name)", arg0: outcome.rawValue)
        let start = uptimeNanoseconds()
        let descriptors = read()
        let microseconds = (uptimeNanoseconds() &- start) / 1_000
        signposter.end(name, interval)
        access.store(microseconds << 2 | outcome.rawValue, ordering: .relaxed)
        return descriptors
    }

    /// The main thread's first ``descriptors()`` read, once it happened.
    public var mainAccess: ActionCatalogMainAccess? {
        let raw = access.load(ordering: .relaxed)
        guard let outcome = ActionCatalogMainAccess.Outcome(rawValue: raw & 0b11) else { return nil }
        return ActionCatalogMainAccess(outcome: outcome, microseconds: raw >> 2)
    }
}
