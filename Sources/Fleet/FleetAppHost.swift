import CmuxFleet
import Foundation

/// Owns the app-side Fleet engine composition.
///
/// The control socket and workstream tap reach Fleet through this host so the
/// engine is instantiated only when the Fleet socket domain is used.
@MainActor
final class FleetAppHost {
    /// The shared app composition host.
    static let shared = FleetAppHost()

    private static var liveHost: FleetAppHost?

    /// Whether an engine has already been instantiated.
    static var hasLiveEngine: Bool {
        liveHost?.engineStorage != nil
    }

    private var engineStorage: FleetEngine?

    /// The lazily constructed Fleet engine.
    var engine: FleetEngine {
        if let engineStorage {
            return engineStorage
        }
        let engine = FleetEngine(dependencies: FleetEngineDependencies(
            actuator: FleetAppActuator(),
            world: FleetAppWorldReader(),
            timers: FleetAppTimers(),
            processWatcher: FleetAppProcessWatcher(),
            persistence: FleetAppPersistence(),
            now: { Date() },
            debugLog: { message in
#if DEBUG
                cmuxDebugLog(message)
#else
                _ = message
#endif
            }
        ))
        engineStorage = engine
        Self.liveHost = self
        return engine
    }

    private init() {}
}
