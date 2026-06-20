/// Builds the two trivial, stateless system probes (`system.ping` and
/// `system.capabilities`) shared by both control-command dispatch lanes.
///
/// ## Why an instance, not a static namespace
///
/// `system.ping` / `system.capabilities` are the only v2 methods that run on
/// BOTH the main-actor lane (the ``ControlCommandCoordinator`` fall-through) and
/// the synchronous `nonisolated` socket-worker lane (they are
/// `mainThreadCallable` in ``ControlCommandExecutionPolicy``). The legacy bodies
/// lived twice in `TerminalController` (once per switch). This value type is the
/// single source of truth both lanes call: the coordinator owns one via
/// ``ControlCommandCoordinator``, and the app's worker lane constructs one
/// inline. It is a real value holding the ``ControlCapabilitiesManifest`` it
/// describes (constructor-injected, defaulting to ``ControlCapabilitiesManifest/frozen``),
/// so it is not a static-method utility in disguise.
///
/// ## Isolation
///
/// `Sendable` and isolation-free: both methods are pure transforms over the
/// injected manifest plus the live `socket_path` / `access_mode` strings passed
/// in by the caller, so the worker lane can call them off the main actor exactly
/// as the legacy worker-lane bodies built their payloads inline.
public struct ControlSystemProbe: Sendable {
    /// The advertised method catalog `system.capabilities` reports.
    private let manifest: ControlCapabilitiesManifest

    /// Creates a probe over a capability manifest.
    ///
    /// - Parameter manifest: The method catalog to advertise. Defaults to the
    ///   shipped ``ControlCapabilitiesManifest/frozen`` catalog.
    public init(manifest: ControlCapabilitiesManifest = .frozen) {
        self.manifest = manifest
    }

    /// `system.ping` — the byte-faithful `{"pong": true}` acknowledgement
    /// (always ok; carries no live state).
    public func ping() -> ControlCallResult {
        .ok(.object(["pong": .bool(true)]))
    }

    /// `system.capabilities` — the protocol/version banner plus the live
    /// `socket_path` / `access_mode` and the sorted method catalog. Byte-faithful
    /// to the former `TerminalController.v2Capabilities`: the DEBUG build adds the
    /// manifest's DEBUG-only methods, and the union is emitted `.sorted()`.
    ///
    /// - Parameters:
    ///   - socketPath: The server's current socket path.
    ///   - accessModeRawValue: The server access mode's raw value.
    /// - Returns: The capabilities call result (always ok).
    public func capabilities(socketPath: String, accessModeRawValue: String) -> ControlCallResult {
#if DEBUG
        let methods = manifest.releaseMethods + manifest.debugMethods
#else
        let methods = manifest.releaseMethods
#endif
        return .ok(.object([
            "protocol": .string("cmux-socket"),
            "version": .int(2),
            "socket_path": .string(socketPath),
            "access_mode": .string(accessModeRawValue),
            "methods": .array(methods.sorted().map { .string($0) }),
        ]))
    }
}
