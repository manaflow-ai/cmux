public import CmuxTerminalClientModel
internal import CmuxTerminalClientFFI
public import Foundation

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
    /// the route throws an error mentioning "invitation".
    public static func connect(
        route: String,
        stateDirectory: URL,
        deviceName: String,
        invitation: String? = nil,
        wireGuard: WireGuardNet? = nil,
        timeout: Duration = .seconds(30)
    ) throws -> TerminalClient {
        var error = [CChar](repeating: 0, count: 1024)
        let raw = invitation.withOptionalCString { invitationPointer in
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
        guard let raw else { throw TerminalClientError.failed(String(cString: error)) }
        return TerminalClient(raw: raw, wireGuard: wireGuard)
    }

    deinit {
        cmux_terminal_client_set_output_callback(raw, nil, nil)
        cmux_terminal_client_disconnect(raw)
    }

    /// Install before `attach`. Runs on library worker threads; hop to the
    /// main actor before touching UI.
    public func setOutputHandler(_ handler: (@Sendable (TerminalOutputEvent) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        guard let handler else {
            cmux_terminal_client_set_output_callback(raw, nil, nil)
            outputBox = nil
            return
        }
        let box = OutputBox(handler: handler)
        outputBox = box
        cmux_terminal_client_set_output_callback(
            raw, outputTrampoline, Unmanaged.passUnretained(box).toOpaque())
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
    init(handler: @Sendable @escaping (TerminalOutputEvent) -> Void) {
        self.handler = handler
    }
}

private let outputTrampoline: CmuxTerminalClientOutputCallback = { context, kind, bytes, length, cols, rows in
    guard let context else { return }
    let box = Unmanaged<OutputBox>.fromOpaque(context).takeUnretainedValue()
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
