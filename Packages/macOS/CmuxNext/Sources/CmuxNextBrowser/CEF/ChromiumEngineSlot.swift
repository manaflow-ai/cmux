public import CmuxNextWakeups

/// The App's Chromium engine, built on its first read instead of at launch (p08-startup-024, Q1).
///
/// The stores and the wait deadlines both engines share are here before the engine, so the WebKit engine
/// and the tab service never build it. `engineDidCreate` wires the engine as it is built, before any reader
/// gets it: only an engine starts Chromium, so the App's crash handlers (`AppRunMarker.keepSignalHandlers`)
/// are always set before CefInitialize. Chrome builds its browser-process services the same way, on first
/// use through a factory (`BrowserContextKeyedServiceFactory::GetForBrowserContext`,
/// components/keyed_service/content/browser_context_keyed_service_factory.cc).
public final class ChromiumEngineSlot {
    /// The browser stores both engines and the App share (``BrowserSharedStores``).
    public let stores: BrowserSharedStores
    /// The main thread's deadline queue the pages' keyed waits use, shared with the WebKit engine.
    public let waitDeadlines: MainWakeUpQueue
    private let make: (BrowserSharedStores, MainWakeUpQueue) -> CEFEngine
    private let engineDidCreate: (CEFEngine) -> Void
    /// The engine once a reader built it; nil before.
    public private(set) var built: CEFEngine?

    /// - Parameters:
    ///   - make: Builds the engine over `stores` and `waitDeadlines`; runs once, at the first read of ``engine``.
    ///   - engineDidCreate: Runs once with the built engine, before the reader that built it gets it.
    public init(stores: BrowserSharedStores, waitDeadlines: MainWakeUpQueue,
         make: @escaping (BrowserSharedStores, MainWakeUpQueue) -> CEFEngine,
         engineDidCreate: @escaping (CEFEngine) -> Void = { _ in }) {
        (self.stores, self.waitDeadlines) = (stores, waitDeadlines)
        self.make = make
        self.engineDidCreate = engineDidCreate
    }

    /// A slot over an engine built already (tests and fixtures).
    public convenience init(_ engine: CEFEngine) {
        self.init(stores: engine.stores, waitDeadlines: engine.waitDeadlines, make: { _, _ in engine })
    }

    /// The engine, built and wired on the first read. A read from inside `engineDidCreate` gets the same engine.
    public var engine: CEFEngine {
        if let built { return built }
        let engine = make(stores, waitDeadlines)
        built = engine
        engineDidCreate(engine)
        return engine
    }
}
