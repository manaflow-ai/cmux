import CmuxTerminalAccess
import Foundation

/// Owns the HTTPControlServer instance and reconciles it against the
/// live ``HTTPControlSettings``.
///
/// On launch ``cmuxApp`` constructs one lifecycle, calls
/// ``applySettings()`` to bring the listener up to match the persisted
/// settings, then registers a `UserDefaults.didChangeNotification`
/// observer that re-applies on every defaults write. The observer is
/// coarse (any defaults write triggers a reconcile); the cost is one
/// listener stop+start when settings actually change, and a no-op
/// otherwise.
///
/// Token rotation through ``rotateTokenAndRestart()`` writes the new
/// token AND restarts the listener so existing connections — which
/// captured the OLD token in their auth state — are dropped. This is
/// spec §16.3 + D30: rotating the token invalidates running sessions.
///
/// Wire-up: a future commit in `cmuxApp.swift` (or `AppDelegate`)
/// creates the lifecycle once per process and holds a strong
/// reference; ``HTTPControlSettingsViewModel.onTokenRotated`` is
/// pointed at ``rotateTokenAndRestart(_:)`` so the Settings "Rotate"
/// button kicks the listener.
public final class HTTPControlLifecycle: @unchecked Sendable {
    /// Settings instance this lifecycle reconciles against.
    public let settings: HTTPControlSettings

    private let service: any TerminalAccessService
    private let lock = NSLock()
    private var server: HTTPControlServer?
    private var lastTransport: HTTPControlSettings.Transport?
    private var observer: NSObjectProtocol?

    /// TCP port the listener bound to. `nil` when disabled or when
    /// the transport is UDS. The lifecycle test reads this after
    /// ``applySettings()`` to assert the listener really started.
    public private(set) var boundPort: UInt16?

    /// Builds a lifecycle bound to `settings` + `service`.
    ///
    /// - Parameters:
    ///   - settings: Persisted settings instance (one per process).
    ///   - service: The `TerminalAccessService` the HTTP routes
    ///     dispatch into. Production passes the wrapping default
    ///     service over `AppSurfaceProvider.shared`; tests can pass
    ///     a stub.
    public init(settings: HTTPControlSettings, service: any TerminalAccessService) {
        self.settings = settings
        self.service = service
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Brings the listener up (or down) so it matches the current
    /// values on ``settings``. Safe to call repeatedly — idempotent
    /// when nothing changed; stops + restarts otherwise.
    public func applySettings() {
        lock.lock()
        let previous = server
        server = nil
        boundPort = nil
        lock.unlock()
        previous?.stop()

        guard settings.enabled else { return }

        let token = (try? settings.ensureToken()) ?? ""
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: service)
        HTTPControlRoutes.registerScreenRead(into: &table, service: service)
        HTTPControlRoutes.registerInputWrite(
            into: &table,
            service: service,
            allowRaw: { [settings] in settings.allowRawInput }
        )
        let next = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: token),
            hostAllowlistFor: { port in HostAllowlist(port: Int(port)) },
            isEnabled: { [settings] in settings.enabled }
        )
        do {
            switch settings.transport {
            case .tcp:
                let port = try next.startTCP(port: UInt16(settings.tcpPort))
                lock.lock()
                boundPort = port
                server = next
                lastTransport = .tcp
                lock.unlock()
            case .uds:
                try next.startUDS(path: settings.udsPath)
                lock.lock()
                boundPort = 0
                server = next
                lastTransport = .uds
                lock.unlock()
            }
        } catch {
            #if DEBUG
            cmuxDebugLog("HTTPControlLifecycle.applySettings failed: \(error)")
            #endif
        }
    }

    /// Rotates the bearer token AND restarts the listener so existing
    /// accepted connections drop (D30 / spec §16.3). Returns the new
    /// token so the Settings pane can show it without a second read.
    @discardableResult
    public func rotateTokenAndRestart() throws -> String {
        let t = try settings.rotateToken()
        applySettings()
        return t
    }

    /// Starts observing `UserDefaults.didChangeNotification` so any
    /// change to the settings panel re-runs ``applySettings()``.
    /// The observer is coarse-grained on purpose — the only defaults
    /// keys affecting the listener live under `httpControl.*`, so
    /// foreign writes degrade to a cheap no-op.
    ///
    /// - Parameter defaults: `UserDefaults` instance to observe. Pass
    ///   the same instance the underlying settings is bound to.
    public func startObserving(defaults: UserDefaults = .standard) {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.applySettings()
        }
    }

    /// Stops the listener and removes the observer. Intended for
    /// teardown in tests; the production process holds the lifecycle
    /// for its lifetime.
    public func shutdown() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        lock.lock()
        let s = server
        server = nil
        boundPort = nil
        lock.unlock()
        s?.stop()
    }
}
