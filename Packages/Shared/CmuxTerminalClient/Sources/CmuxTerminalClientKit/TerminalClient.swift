public import CmuxTerminalClientModel
internal import CmuxTerminalClientFFI
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

/// An in-process WireGuard tunnel. Shareable by any number of clients; keep it
/// alive until every client that used it has been released.
public final class WireGuardNet: @unchecked Sendable {
    let raw: OpaquePointer

    /// `wgQuickConfig` is wg-quick text with `PrivateKey` present. The text is
    /// parsed in memory and not written anywhere.
    public init(wgQuickConfig: String) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let raw = cmux_wireguard_net_start(wgQuickConfig, &error, error.count) else {
            throw TerminalClientError.failed(String(cString: error))
        }
        self.raw = raw
    }

    deinit {
        cmux_wireguard_net_free(raw)
    }
}

/// One authenticated link to a cmux daemon with a persistent device identity.
public final class TerminalClient: @unchecked Sendable {
    private let raw: OpaquePointer
    /// Retained while an output handler is installed; the C callback context.
    private var outputBox: OutputBox?
    /// Most recently requested handler. A callback can request replacement
    /// while the FFI is synchronously draining the old callback, so that
    /// request is applied after the drain returns.
    private var requestedOutputBox: OutputBox?
    private var outputCallbackUpdateInFlight = false
    private var outputCallbackDepth = 0
    /// Held so the tunnel outlives this client.
    private let wireGuard: WireGuardNet?
    private let lock = NSLock()

    private init(raw: OpaquePointer, wireGuard: WireGuardNet?) {
        self.raw = raw
        self.wireGuard = wireGuard
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
        setOutputHandler(nil)
        cmux_terminal_client_disconnect(raw)
    }

    /// Install before `attach`. Runs on library worker threads; hop to the
    /// main actor before touching UI.
    public func setOutputHandler(_ handler: (@Sendable (TerminalOutputEvent) -> Void)?) {
        let requested = handler.map { OutputBox(handler: $0, owner: self) }
        lock.lock()
        requestedOutputBox = requested
        if outputCallbackUpdateInFlight {
            lock.unlock()
            return
        }
        outputCallbackUpdateInFlight = true
        let deferUntilCallbackReturns = outputCallbackDepth > 0
        lock.unlock()
        if deferUntilCallbackReturns {
            // The FFI waits for the active callback to return. Applying from
            // this callback would deadlock if the handler replaces itself.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.applyOutputHandlerUpdates()
            }
        } else {
            applyOutputHandlerUpdates()
        }
    }

    fileprivate func beginOutputCallback() {
        lock.lock()
        outputCallbackDepth += 1
        lock.unlock()
    }

    fileprivate func endOutputCallback() {
        lock.lock()
        outputCallbackDepth = max(0, outputCallbackDepth - 1)
        lock.unlock()
    }

    private func applyOutputHandlerUpdates() {
        while true {
            lock.lock()
            let installed = outputBox
            let requested = requestedOutputBox
            let unchanged =
                (installed == nil && requested == nil)
                || (installed != nil && requested != nil && installed! === requested!)
            if unchanged {
                outputCallbackUpdateInFlight = false
                lock.unlock()
                return
            }
            lock.unlock()

            if let installed {
                // The FFI waits for callbacks already in flight. Keep the
                // context retained locally, and never hold `lock` across this
                // call because the handler can request a deferred replacement.
                cmux_terminal_client_set_output_callback(raw, nil, nil)
                lock.lock()
                if outputBox === installed {
                    outputBox = nil
                }
                lock.unlock()
            }

            lock.lock()
            let latest = requestedOutputBox
            if let latest {
                outputBox = latest
            }
            lock.unlock()

            if let latest {
                cmux_terminal_client_set_output_callback(
                    raw,
                    outputTrampoline,
                    Unmanaged.passUnretained(latest).toOpaque())
            }
        }
    }

    public func listTerminals(timeout: Duration = .seconds(15)) throws -> [TerminalSummary] {
        var error = [CChar](repeating: 0, count: 1024)
        guard let text = cmux_terminal_client_list_terminals(raw, &error, error.count, timeout.milliseconds) else {
            throw TerminalClientError.failed(String(cString: error))
        }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.terminals(fromListResult: Data(bytes: text, count: strlen(text)))
    }

    /// Creates a workspace with one terminal and returns the terminal id.
    public func createTerminal(name: String? = nil, timeout: Duration = .seconds(15)) throws -> String {
        var error = [CChar](repeating: 0, count: 1024)
        let text = name.withOptionalCString { namePointer in
            cmux_terminal_client_create_terminal(raw, namePointer, &error, error.count, timeout.milliseconds)
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
        let text = workspaceID.withCString { workspacePointer in
            name.withOptionalCString { namePointer in
                cmux_terminal_client_create_terminal_in_workspace(
                    raw, workspacePointer, namePointer, &error, error.count, timeout.milliseconds
                )
            }
        }
        guard let text else { throw TerminalClientError.failed(String(cString: error)) }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.createdTerminalID(fromCreateResult: Data(bytes: text, count: strlen(text)))
    }

    public func listWorkspaces(timeout: Duration = .seconds(15)) throws -> [RemoteWorkspaceSummary] {
        var error = [CChar](repeating: 0, count: 1024)
        guard let text = cmux_terminal_client_list_workspaces(raw, &error, error.count, timeout.milliseconds) else {
            throw TerminalClientError.failed(String(cString: error))
        }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.workspaces(fromListResult: Data(bytes: text, count: strlen(text)))
    }

    /// Creates a remote workspace with one starter terminal and returns its id.
    public func createWorkspace(name: String? = nil, timeout: Duration = .seconds(15)) throws -> String {
        var error = [CChar](repeating: 0, count: 1024)
        let text = name.withOptionalCString { namePointer in
            cmux_terminal_client_create_workspace(raw, namePointer, &error, error.count, timeout.milliseconds)
        }
        guard let text else { throw TerminalClientError.failed(String(cString: error)) }
        defer { cmux_terminal_client_string_free(text) }
        return try TerminalCatalogDecoding.createdWorkspaceID(fromCreateResult: Data(bytes: text, count: strlen(text)))
    }

    /// The daemon's workspaces and terminals from one session snapshot, each
    /// terminal placed under the workspace that shows it.
    public func loadCatalog(timeout: Duration = .seconds(15)) throws -> SessionCatalog {
        var error = [CChar](repeating: 0, count: 1024)
        guard let text = cmux_terminal_client_session_snapshot(raw, &error, error.count, timeout.milliseconds) else {
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
        cmux_terminal_client_set_viewer_size_priority(raw, preferred)
    }

    public func attach(terminalID: String, timeout: Duration = .seconds(15)) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard cmux_terminal_client_attach_with_timeout(raw, terminalID, &error, error.count, timeout.milliseconds) else {
            throw TerminalClientError.failed(String(cString: error))
        }
    }

    public func detach() {
        cmux_terminal_client_detach(raw)
    }

    /// Queue input bytes. False means the local queue refused them.
    @discardableResult
    public func send(_ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { buffer in
            cmux_terminal_client_send(raw, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
        }
    }

    @discardableResult
    public func paste(_ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { buffer in
            cmux_terminal_client_paste(raw, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
        }
    }

    @discardableResult
    public func resize(cols: UInt16, rows: UInt16) -> Bool {
        cmux_terminal_client_resize(raw, cols, rows)
    }

    public var hasExited: Bool {
        cmux_terminal_client_has_exited(raw)
    }
}

final class OutputBox: @unchecked Sendable {
    let handler: @Sendable (TerminalOutputEvent) -> Void
    weak var owner: TerminalClient?

    init(
        handler: @Sendable @escaping (TerminalOutputEvent) -> Void,
        owner: TerminalClient
    ) {
        self.handler = handler
        self.owner = owner
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
    guard let context else { return }
    let box = Unmanaged<OutputBox>.fromOpaque(context).takeUnretainedValue()
    let owner = box.owner
    owner?.beginOutputCallback()
    defer { owner?.endOutputCallback() }
    let data = (bytes != nil && length > 0) ? Data(bytes: bytes!, count: length) : Data()
    guard let event = TerminalOutputEvent(kind: kind, bytes: data, cols: cols, rows: rows) else { return }
    box.handler(event)
}

extension Duration {
    fileprivate var milliseconds: UInt64 {
        let (seconds, attoseconds) = components
        let total = seconds * 1_000 + attoseconds / 1_000_000_000_000_000
        return total <= 0 ? 0 : UInt64(total)
    }
}

extension Optional where Wrapped == String {
    fileprivate func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .some(let value): return value.withCString { body($0) }
        case .none: return body(nil)
        }
    }
}
