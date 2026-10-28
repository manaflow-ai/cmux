public import CmuxTerminalClientModel
internal import CmuxTerminalClientFFI
internal import CmuxSafeConcurrency
public import Foundation
import Dispatch

public enum TerminalClientError: Error, Sendable, CustomStringConvertible {
    case failed(String)

    public var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// A native handle (`CmuxTerminalClient *` or `CmuxWireGuardNet *`) that any
/// thread may pass to the C ABI. The pointer never changes; the class that
/// holds it owns the handle and frees it once, after its last use.
// crash-allow: an immutable pointer to a Rust type that cmux-terminal-client's lib.rs asserts is Send + Sync; every entry point but disconnect and free takes it shared, and only the owning class's teardown frees it, once no call uses it (TerminalClientState drains its calls first).
struct NativeHandle: @unchecked Sendable {
    let raw: OpaquePointer
}

/// An in-process WireGuard tunnel. Shareable by any number of clients; keep it
/// alive until every client that used it has been released.
public final class WireGuardNet: Sendable {
    private let handle: NativeHandle
    var raw: OpaquePointer { handle.raw }

    /// `wgQuickConfig` is wg-quick text with `PrivateKey` present. The text is
    /// parsed in memory and not written anywhere.
    public init(wgQuickConfig: String) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let raw = cmux_wireguard_net_start(wgQuickConfig, &error, error.count) else {
            throw TerminalClientError.failed(String(cString: error))
        }
        self.handle = NativeHandle(raw: raw)
    }

    deinit {
        cmux_wireguard_net_free(handle.raw)
    }
}

/// One client's link lifecycle and output-callback registration, shared by
/// the callers' threads (the main actor, Cloud lifecycle tasks), the native
/// output threads and the teardown task. Every mutable field is in `shared`,
/// reached only inside `withLock`, and no lock is held across a native call.
/// Nothing blocks waiting for the calls in flight to drain: the last one to
/// finish after `disconnect` starts the teardown.
private final class TerminalClientState: Sendable {
    private struct Shared {
        /// The installed output handler (the box the native callback is set to, or about to be).
        var outputBox: OutputBox?
        /// The +1 the native client holds as its output callback's context, from the call that sets
        /// the callback until the call that replaces or clears it has returned.
        var nativeOutputContext: Unmanaged<OutputBox>?
        /// Most recently requested handler. A callback can request replacement
        /// while the FFI is synchronously draining the old callback, so that
        /// request is applied after the drain returns.
        var requestedOutputBox: OutputBox?
        var outputCallbackUpdateInFlight = false
        var outputCallbackDepth = 0
        var didDisconnect = false
        var activeFFIOperations = 0
        var teardownClaimed = false

        /// True exactly once: after `disconnect`, when no native operation and
        /// no output callback is running. The caller that gets it starts the teardown.
        mutating func claimTeardown() -> Bool {
            guard didDisconnect, !teardownClaimed, activeFFIOperations == 0, outputCallbackDepth == 0 else {
                return false
            }
            teardownClaimed = true
            return true
        }
    }

    private let handle: NativeHandle
    /// Held so the tunnel outlives this client.
    private let wireGuard: WireGuardNet?
    private let shared = Mutex(Shared())

    init(raw: OpaquePointer, wireGuard: WireGuardNet?) {
        self.handle = NativeHandle(raw: raw)
        self.wireGuard = wireGuard
    }

    /// Schedules closure of the daemon link. Safe to call more than once.
    func disconnect() {
        let claimed = shared.withLock { shared -> Bool in
            guard !shared.didDisconnect else { return false }
            shared.didDisconnect = true
            shared.requestedOutputBox = nil
            return shared.claimTeardown()
        }
        if claimed { scheduleTeardown() }
    }

    /// Closes the native link off the claiming thread. The claim can come from
    /// the main actor (Cloud lifecycle methods), from an output callback (the
    /// C callback must return before its setter can run on its thread) or from
    /// the thread of the last native operation, which may have waited for its
    /// timeout. The task keeps this state, and with it the callback context,
    /// alive until the teardown is done.
    private func scheduleTeardown() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            setNativeOutputCallback(handle.raw, to: nil)
            shared.withLock { $0.outputBox = nil }
            cmux_terminal_client_disconnect(handle.raw)
        }
    }

    /// Points the native output callback at `box` (nil clears it). The native client takes a +1
    /// on `box` as the callback's context and drops the previous one only after the call returns,
    /// since the native client waits for callbacks already in flight before it returns. Never
    /// called with the lock held: the handler can request a deferred replacement. Calls never
    /// overlap: updates run one at a time inside `withConnectedFFI`, and the teardown only after
    /// every such call has returned.
    private func setNativeOutputCallback(_ raw: OpaquePointer, to box: OutputBox?) {
        let next = box.map { Unmanaged.passRetained($0) }
        let callback: OutputCallback? = next == nil ? nil : outputTrampoline
        cmux_terminal_client_set_output_callback(raw, callback, next?.toOpaque())
        let previous = shared.withLock { shared -> Unmanaged<OutputBox>? in
            let previous = shared.nativeOutputContext
            shared.nativeOutputContext = next
            return previous
        }
        previous?.release()
    }

    func withConnectedFFI<Result>(
        _ operation: (OpaquePointer) throws -> Result
    ) throws -> Result {
        let entered = shared.withLock { shared -> Bool in
            guard !shared.didDisconnect else { return false }
            shared.activeFFIOperations += 1
            return true
        }
        guard entered else {
            throw TerminalClientError.failed("Terminal client is disconnected")
        }
        defer {
            let claimed = shared.withLock { shared -> Bool in
                shared.activeFFIOperations -= 1
                return shared.claimTeardown()
            }
            if claimed { scheduleTeardown() }
        }
        return try operation(handle.raw)
    }

    func setOutputHandler(_ requested: OutputBox?) {
        let start = shared.withLock { shared -> (apply: Bool, afterCallback: Bool) in
            guard !shared.didDisconnect else { return (false, false) }
            shared.requestedOutputBox = requested
            guard !shared.outputCallbackUpdateInFlight else { return (false, false) }
            shared.outputCallbackUpdateInFlight = true
            return (true, shared.outputCallbackDepth > 0)
        }
        guard start.apply else { return }
        if start.afterCallback {
            // The FFI waits for the active callback to return. Applying from
            // this callback would deadlock if the handler replaces itself.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                applyOutputHandlerUpdates()
            }
        } else {
            applyOutputHandlerUpdates()
        }
    }

    func beginOutputCallback() {
        shared.withLock { $0.outputCallbackDepth += 1 }
    }

    func endOutputCallback() {
        let claimed = shared.withLock { shared -> Bool in
            shared.outputCallbackDepth = max(0, shared.outputCallbackDepth - 1)
            return shared.claimTeardown()
        }
        if claimed { scheduleTeardown() }
    }

    private func abandonOutputHandlerUpdate() {
        shared.withLock { shared in
            // A failed update can race with disconnect after it has read the
            // installed box but before `withConnectedFFI` enters the native call.
            // The native client still holds that box's context until the
            // teardown clears the callback, so let that path drop it.
            if !shared.didDisconnect {
                shared.outputBox = nil
            }
            shared.requestedOutputBox = nil
            shared.outputCallbackUpdateInFlight = false
        }
    }

    private func applyOutputHandlerUpdates() {
        while true {
            let step = shared.withLock { shared -> (done: Bool, installed: OutputBox?) in
                if shared.outputBox === shared.requestedOutputBox {
                    shared.outputCallbackUpdateInFlight = false
                    return (true, nil)
                }
                return (false, shared.outputBox)
            }
            if step.done { return }

            if let installed = step.installed {
                // The FFI waits for callbacks already in flight. Keep the
                // context retained locally, and never hold the lock across this
                // call because the handler can request a deferred replacement.
                do {
                    try withConnectedFFI { raw in
                        setNativeOutputCallback(raw, to: nil)
                    }
                } catch {
                    abandonOutputHandlerUpdate()
                    return
                }
                shared.withLock { shared in
                    if shared.outputBox === installed {
                        shared.outputBox = nil
                    }
                }
            }

            let latest = shared.withLock { shared -> OutputBox? in
                if let latest = shared.requestedOutputBox {
                    shared.outputBox = latest
                }
                return shared.requestedOutputBox
            }

            if let latest {
                do {
                    try withConnectedFFI { raw in
                        setNativeOutputCallback(raw, to: latest)
                    }
                } catch {
                    abandonOutputHandlerUpdate()
                    return
                }
            }
        }
    }
}

/// One authenticated link to a cmux daemon with a persistent device identity.
public final class TerminalClient: Sendable {
    private let state: TerminalClientState

    private init(raw: OpaquePointer, wireGuard: WireGuardNet?) {
        self.state = TerminalClientState(raw: raw, wireGuard: wireGuard)
    }

    /// Connect by route. `stateDirectory` must persist across launches and be
    /// private to this device. Pass `invitation` for the first contact with a
    /// daemon and nil afterwards. A nil invitation with no enrolled daemon for
    /// the route throws an error mentioning "invitation". `trustedCarrier` is
    /// an explicit Cloud API grant and requires a route inside `wireGuard`.
    public static func connect(
        route: String,
        stateDirectory: URL,
        deviceName: String,
        invitation: String? = nil,
        trustedCarrier: Bool = false,
        wireGuard: WireGuardNet? = nil,
        timeout: Duration = .seconds(30)
    ) throws -> TerminalClient {
        var error = [CChar](repeating: 0, count: 1024)
        let raw: OpaquePointer?
        if trustedCarrier {
            guard invitation == nil else {
                throw TerminalClientError.failed("Trusted Cloud access cannot also use an invitation")
            }
            guard let wireGuard else {
                throw TerminalClientError.failed("Trusted Cloud access requires a WireGuard tunnel")
            }
            guard cmux_wireguard_net_route_is_allowed(
                wireGuard.raw, route, &error, error.count)
            else {
                throw TerminalClientError.failed(String(cString: error))
            }
            raw = cmux_terminal_client_connect_trusted_route(
                route, stateDirectory.path, deviceName, wireGuard.raw,
                &error, error.count, timeout.milliseconds)
        } else {
            raw = invitation.withOptionalCString { invitationPointer in
                cmux_terminal_client_connect_route(
                    route,
                    stateDirectory.path,
                    deviceName,
                    invitationPointer,
                    wireGuard?.raw,
                    &error,
                    error.count,
                    timeout.milliseconds)
            }
        }
        guard let raw else { throw TerminalClientError.failed(String(cString: error)) }
        return TerminalClient(raw: raw, wireGuard: wireGuard)
    }

    deinit {
        state.disconnect()
    }

    /// Schedules closure of the daemon link. Safe to call more than once.
    public func disconnect() {
        state.disconnect()
    }

    /// Install before `attach`. Runs on library worker threads; hop to the
    /// main actor before touching UI.
    public func setOutputHandler(_ handler: (@Sendable (TerminalOutputEvent) -> Void)?) {
        let requested = handler.map { OutputBox(handler: $0, state: state) }
        state.setOutputHandler(requested)
    }

    public func listTerminals(timeout: Duration = .seconds(15)) throws -> [TerminalSummary] {
        var error = [CChar](repeating: 0, count: 1024)
        guard let text = try state.withConnectedFFI({ raw in
            cmux_terminal_client_list_terminals(raw, &error, error.count, timeout.milliseconds)
        }) else {
            throw TerminalClientError.failed(String(cString: error))
        }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.terminals(fromListResult: Data(bytes: text, count: strlen(text)))
    }

    /// Creates a workspace with one terminal and returns the terminal id.
    public func createTerminal(name: String? = nil, timeout: Duration = .seconds(15)) throws -> String {
        var error = [CChar](repeating: 0, count: 1024)
        let text = try name.withOptionalCString { namePointer in
            try state.withConnectedFFI { raw in
                cmux_terminal_client_create_terminal(raw, namePointer, &error, error.count, timeout.milliseconds)
            }
        }
        guard let text else { throw TerminalClientError.failed(String(cString: error)) }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.createdTerminalID(fromCreateResult: Data(bytes: text, count: strlen(text)))
    }

    /// Creates a terminal in `workspaceID`'s focused pane, where it becomes
    /// the selected tab, and returns its id. The session's focused workspace
    /// does not move.
    public func createTerminal(
        inWorkspace workspaceID: String,
        name: String? = nil,
        timeout: Duration = .seconds(15)
    ) throws -> String {
        var error = [CChar](repeating: 0, count: 1024)
        let text = try workspaceID.withCString { workspacePointer in
            try name.withOptionalCString { namePointer in
                try state.withConnectedFFI { raw in
                    cmux_terminal_client_create_terminal_in_workspace(
                        raw, workspacePointer, namePointer, &error, error.count, timeout.milliseconds
                    )
                }
            }
        }
        guard let text else { throw TerminalClientError.failed(String(cString: error)) }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.createdTerminalID(fromCreateResult: Data(bytes: text, count: strlen(text)))
    }

    public func listWorkspaces(timeout: Duration = .seconds(15)) throws -> [RemoteWorkspaceSummary] {
        var error = [CChar](repeating: 0, count: 1024)
        guard let text = try state.withConnectedFFI({ raw in
            cmux_terminal_client_list_workspaces(raw, &error, error.count, timeout.milliseconds)
        }) else {
            throw TerminalClientError.failed(String(cString: error))
        }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.workspaces(fromListResult: Data(bytes: text, count: strlen(text)))
    }

    /// Creates a remote workspace with one starter terminal and returns its id.
    public func createWorkspace(name: String? = nil, timeout: Duration = .seconds(15)) throws -> String {
        var error = [CChar](repeating: 0, count: 1024)
        let text = try name.withOptionalCString { namePointer in
            try state.withConnectedFFI { raw in
                cmux_terminal_client_create_workspace(raw, namePointer, &error, error.count, timeout.milliseconds)
            }
        }
        guard let text else { throw TerminalClientError.failed(String(cString: error)) }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.createdWorkspaceID(fromCreateResult: Data(bytes: text, count: strlen(text)))
    }

    /// The daemon's workspaces and terminals from one session snapshot, each
    /// terminal placed under the workspace that shows it.
    public func loadCatalog(timeout: Duration = .seconds(15)) throws -> SessionCatalog {
        var error = [CChar](repeating: 0, count: 1024)
        guard let text = try state.withConnectedFFI({ raw in
            cmux_terminal_client_session_snapshot(raw, &error, error.count, timeout.milliseconds)
        }) else {
            throw TerminalClientError.failed(String(cString: error))
        }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.catalog(fromSnapshot: Data(bytes: text, count: strlen(text)))
    }

    /// Asks the daemon to size attached terminals to this client's grid even
    /// while other viewers share them. Read when an attach begins; a daemon
    /// or terminal host that predates it keeps sharing the smallest grid.
    @discardableResult
    public func setViewerSizePriority(_ preferred: Bool) -> Bool {
        (try? state.withConnectedFFI { raw in
            cmux_terminal_client_set_viewer_size_priority(raw, preferred)
        }) ?? false
    }

    public func attach(terminalID: String, timeout: Duration = .seconds(15)) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard try state.withConnectedFFI({ raw in
            cmux_terminal_client_attach_with_timeout(raw, terminalID, &error, error.count, timeout.milliseconds)
        }) else {
            throw TerminalClientError.failed(String(cString: error))
        }
    }

    public func detach() {
        _ = try? state.withConnectedFFI { raw in
            cmux_terminal_client_detach(raw)
        }
    }

    /// Queue input bytes. False means the local queue refused them.
    @discardableResult
    public func send(_ bytes: Data) -> Bool {
        (try? state.withConnectedFFI { raw in
            bytes.withUnsafeBytes { buffer in
                cmux_terminal_client_send(raw, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
            }
        }) ?? false
    }

    @discardableResult
    public func paste(_ bytes: Data) -> Bool {
        (try? state.withConnectedFFI { raw in
            bytes.withUnsafeBytes { buffer in
                cmux_terminal_client_paste(raw, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
            }
        }) ?? false
    }

    @discardableResult
    public func resize(cols: UInt16, rows: UInt16) -> Bool {
        (try? state.withConnectedFFI { raw in
            cmux_terminal_client_resize(raw, cols, rows)
        }) ?? false
    }

    public var hasExited: Bool {
        (try? state.withConnectedFFI { raw in
            cmux_terminal_client_has_exited(raw)
        }) ?? false
    }
}

/// One installed output handler; the native client holds a +1 on it as the
/// output callback's context. It keeps the client's state alive while a
/// callback runs, so the callback's begin and end always reach the state that
/// drains them, even while the `TerminalClient` itself is going away. The
/// state drops its references when the handler is replaced or the link is torn
/// down, which ends the cycle.
private final class OutputBox: Sendable {
    let handler: @Sendable (TerminalOutputEvent) -> Void
    let state: TerminalClientState

    init(
        handler: @Sendable @escaping (TerminalOutputEvent) -> Void,
        state: TerminalClientState
    ) {
        self.handler = handler
        self.state = state
    }
}

private typealias OutputCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UInt32,
    UnsafePointer<UInt8>?,
    Int,
    UInt16,
    UInt16
) -> Void

private let outputTrampoline: OutputCallback = { context, kind, bytes, length, cols, rows in
    // A non-NULL context is the +1 box `setNativeOutputCallback` gave the native client, which
    // holds it until the call that replaces or clears the callback has returned.
    guard let context else { return }
    let box = Unmanaged<OutputBox>.fromOpaque(context).takeUnretainedValue()
    box.state.beginOutputCallback()
    defer { box.state.endOutputCallback() }
    let data = (bytes != nil && length > 0) ? Data(bytes: bytes!, count: length) : Data()
    guard let event = TerminalOutputEvent(kind: kind, bytes: data, cols: cols, rows: rows) else { return }
    box.handler(event)
}

extension Duration {
    fileprivate var milliseconds: UInt64 {
        let (seconds, attoseconds) = components
        guard seconds >= 0, attoseconds >= 0 else { return 0 }
        let (wholeMilliseconds, secondsOverflowed) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !secondsOverflowed else { return .max }
        let fractionalMilliseconds = attoseconds / 1_000_000_000_000_000
        let (total, fractionalOverflowed) = wholeMilliseconds.addingReportingOverflow(fractionalMilliseconds)
        guard !fractionalOverflowed else { return .max }
        return total == 0 ? 1 : UInt64(total)
    }
}

extension Optional where Wrapped == String {
    fileprivate func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
        switch self {
        case .some(let value): return try value.withCString { try body($0) }
        case .none: return try body(nil)
        }
    }
}
