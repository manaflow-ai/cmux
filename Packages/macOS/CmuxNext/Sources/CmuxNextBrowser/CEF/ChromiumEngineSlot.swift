public import CmuxNextWakeups

/// The App's Chromium engine, built on its first read instead of at launch (Q1).
///
/// The stores, the wait deadlines and the runtime source both engines and the launch readers need are here
/// before the engine, so the WebKit engine, the tab service, the page host and the settings followers never
/// build it: a question ("can Chromium open a tab?") is answered from the source, a setting is applied by
/// ``whenBuilt(_:)``. `engineDidCreate` wires the engine as it is built, before any reader gets it: only an
/// engine starts Chromium, so the App's crash handlers (`AppRunMarker.keepSignalHandlers`) are always set
/// before CefInitialize. Chrome builds its browser-process services the same way, on first use through a
/// factory (`BrowserContextKeyedServiceFactory::GetForBrowserContext`,
/// components/keyed_service/content/browser_context_keyed_service_factory.cc).
public final class ChromiumEngineSlot {
    /// The browser stores both engines and the App share (``BrowserSharedStores``).
    public let stores: BrowserSharedStores
    /// The main thread's deadline queue the pages' keyed waits use, shared with the WebKit engine.
    public let waitDeadlines: MainWakeUpQueue
    /// Where the engine's runtime comes from; the engine is built over it.
    public let source: CEFRuntimeSource
    /// A restored page's launch order, over the launch's scheduler while feature `cefLaunchOrigin`
    /// is on, else over none (every page `.user`, at once). The engine orders its starts over the same scheduler.
    public let launchOrder: CEFLaunchDeferral
    private let make: (BrowserSharedStores, MainWakeUpQueue, CEFRuntimeSource) -> CEFEngine
    private let engineDidCreate: (CEFEngine) -> Void
    private let stop: @MainActor (CEFEngine) async -> Void
    /// ``whenBuilt(_:)`` work waiting for the engine, in the order it was asked.
    private var pending: [(CEFEngine) -> Void] = []
    /// The engine once a reader built it; nil before.
    public private(set) var built: CEFEngine?

    /// - Parameters:
    ///   - launch: The launch's scheduler with feature `cefLaunchOrigin` on, else nil (``launchOrder``); `make` gives it to the engine.
    ///   - make: Builds the engine over `stores`, `waitDeadlines` and `source`; runs once, at the first read of ``engine``.
    ///   - engineDidCreate: Runs once with the built engine, before ``whenBuilt(_:)`` work and before the reader
    ///     that built it gets it.
    ///   - stop: Stops a built engine at quit (``shutdown()``): the App passes `CEFEngine.shutdown`, tests a recorder.
    public init(stores: BrowserSharedStores, waitDeadlines: MainWakeUpQueue, source: CEFRuntimeSource, launch: StartupScheduler? = nil,
                make: @escaping (BrowserSharedStores, MainWakeUpQueue, CEFRuntimeSource) -> CEFEngine,
                engineDidCreate: @escaping (CEFEngine) -> Void = { _ in },
                stop: @escaping @MainActor (CEFEngine) async -> Void) {
        (self.stores, self.waitDeadlines, self.source) = (stores, waitDeadlines, source)
        launchOrder = CEFLaunchDeferral(startup: launch)
        self.make = make
        self.engineDidCreate = engineDidCreate
        self.stop = stop
    }

    /// A slot over an engine built already (tests and fixtures): ``built`` from the start.
    public convenience init(_ engine: CEFEngine) {
        self.init(stores: engine.stores, waitDeadlines: engine.waitDeadlines, source: engine.runtimeSource,
                  launch: engine.launchDeferral.startup, make: { _, _, _ in engine }, stop: { await $0.shutdown() })
        built = engine
    }

    /// The engine, built and wired on the first read. A read from inside `engineDidCreate` or ``whenBuilt(_:)``
    /// work gets the same engine.
    public var engine: CEFEngine {
        if let built { return built }
        let engine = make(stores, waitDeadlines, source)
        built = engine
        engineDidCreate(engine)
        let waiting = pending
        pending = []
        for work in waiting { work(engine) }
        return engine
    }

    /// The engine's ``CEFEngine/unavailableReason``, answered without building it.
    public var unavailableReason: CEFUnavailableReason? { CEFEngine.unavailableReason(source: source) }

    /// Runs `work` on the engine: now when it is built, else as it is built (after `engineDidCreate`). A
    /// follower applies a setting here once and to ``built`` on each change, so it never builds the engine.
    public func whenBuilt(_ work: @escaping (CEFEngine) -> Void) {
        if let built { work(built) } else { pending.append(work) }
    }

    /// Stops the engine at quit when one was built; a slot that built none started no Chromium and builds none now.
    public func shutdown() async {
        guard let built else { return }
        await stop(built)
    }
}
