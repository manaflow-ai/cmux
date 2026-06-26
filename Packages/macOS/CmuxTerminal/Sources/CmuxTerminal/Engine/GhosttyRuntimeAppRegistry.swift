import Foundation
public import GhosttyKit

/// Process-wide lookup from a live `ghostty_app_t` handle back to the cmux
/// runtime-app object (`App`) that owns it.
///
/// Ghostty C callbacks (the action callback in particular) arrive carrying only
/// the opaque `ghostty_app_t` and must resolve the owning runtime-app object
/// synchronously, possibly while that object is still inside its own
/// initializer (`ghostty_app_new` can fire callbacks before it returns, so the
/// handle is not yet registered). cmux owns one process-lifetime runtime app, so
/// this registry resolves the owner without re-entering a singleton and without
/// adding a teardown path for a `ghostty_app_t` that is never freed/recreated.
///
/// Generic over `App: AnyObject` because the owning runtime-app type lives in
/// the app target; the registry stores it as an opaque reference keyed by the
/// handle's bit pattern.
///
/// Isolation design: the C callbacks fire on whatever thread libghostty uses and
/// cannot `await`, while registration happens on the main thread during engine
/// initialization. This is the sanctioned "small value read by synchronous
/// callbacks" shape, so the state is guarded by an `NSLock` rather than an actor;
/// an actor would force the synchronous callback to hop and change the resolve
/// timing. The lock serializes every access, which is why the type is
/// `@unchecked Sendable`.
public final class GhosttyRuntimeAppRegistry<App: AnyObject>: @unchecked Sendable {
    // SAFETY: every access to `registry` and `initializingRuntimeApp` is taken
    // under `lock`, so the mutable state is never touched concurrently; the
    // stored `App` references are only ever handed back to callers that already
    // own them.
    private let lock = NSLock()
    private var registry: [UInt: App] = [:]
    private var initializingRuntimeApp: App?

    /// Creates an empty registry.
    public init() {}

    /// Records that `runtimeApp` owns the live `app` handle.
    public func register(_ runtimeApp: App, for app: ghostty_app_t) {
        let key = UInt(bitPattern: app)
        lock.lock()
        registry[key] = runtimeApp
        lock.unlock()
    }

    /// Marks the runtime app currently initializing its `ghostty_app_t`, so a
    /// callback that fires before `register(_:for:)` can still resolve the owner.
    /// Pass `nil` once initialization finishes.
    public func setInitializing(_ runtimeApp: App?) {
        lock.lock()
        initializingRuntimeApp = runtimeApp
        lock.unlock()
    }

    /// The runtime app registered for `app`, or `nil` for a `nil` or unregistered
    /// handle.
    public func runtimeApp(for app: ghostty_app_t?) -> App? {
        guard let app else { return nil }
        let key = UInt(bitPattern: app)
        lock.lock()
        defer { lock.unlock() }
        return registry[key]
    }

    /// Resolves the runtime app for an action callback: the registered owner of
    /// `app` if present, otherwise the runtime app currently initializing (which
    /// covers callbacks fired during `ghostty_app_new` before registration).
    public func runtimeAppForActionCallback(_ app: ghostty_app_t?) -> App? {
        lock.lock()
        defer { lock.unlock() }
        if let app {
            let key = UInt(bitPattern: app)
            if let registered = registry[key] {
                return registered
            }
        }
        return initializingRuntimeApp
    }
}
