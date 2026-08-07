internal import Darwin
internal import Foundation

typealias CmuxTUIUpdateCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

struct CmuxTUIRenderEventDescriptor {
    var kind: UInt32 = 0
    var columns: UInt16 = 0
    var rows: UInt16 = 0
    var payloadLength: Int = 0
}

let cmuxTUIStringMaximumPayloadBytes = 16 * 1_048_576
let cmuxTUIStringMaximumAttempts = 4

func copyBoundedCString(
    maximumPayloadBytes: Int = cmuxTUIStringMaximumPayloadBytes,
    maximumAttempts: Int = cmuxTUIStringMaximumAttempts,
    _ copy: (_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int
) -> String? {
    guard maximumPayloadBytes >= 0,
          maximumPayloadBytes < Int.max,
          maximumAttempts > 0 else {
        return nil
    }
    let maximumCapacity = maximumPayloadBytes + 1
    let initialLength = copy(nil, 0)
    guard initialLength >= 0, initialLength < maximumCapacity else { return nil }
    var capacity = initialLength + 1

    for _ in 0..<maximumAttempts {
        var buffer = [CChar](repeating: 0, count: capacity)
        let actual = copy(&buffer, buffer.count)
        guard actual >= 0 else { return nil }
        if actual < buffer.count {
            return String(
                decoding: buffer.prefix(actual).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
        guard actual < maximumCapacity else { return nil }
        capacity = actual + 1
    }
    return nil
}

// The dlopen handle and resolved function table are immutable after init. The
// Rust client synchronizes the pointed-to handles used by concurrent actors.
final class CmuxTUIClientLibrary: @unchecked Sendable {
    private typealias ABIVersion = @convention(c) () -> UInt32
    private typealias Connect = @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int, UInt64
    ) -> OpaquePointer?
    private typealias SetUpdateCallback = @convention(c) (
        OpaquePointer?, CmuxTUIUpdateCallback?, UnsafeMutableRawPointer?
    ) -> Void
    private typealias Request = @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Bool,
        UnsafeMutablePointer<CChar>?, Int
    ) -> UnsafeMutablePointer<CChar>?
    private typealias StringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias AttachTerminal = @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int, UInt64
    ) -> OpaquePointer?
    private typealias CopyString = @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<CChar>?, Int
    ) -> Int
    private typealias Disconnect = @convention(c) (OpaquePointer?) -> Void
    private typealias TerminalSend = @convention(c) (
        OpaquePointer?, UnsafePointer<UInt8>?, Int
    ) -> Bool
    private typealias TerminalSendKey = @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, Bool
    ) -> Bool
    private typealias TerminalResize = @convention(c) (
        OpaquePointer?, UInt16, UInt16
    ) -> Bool
    private typealias CopyRenderEvent = @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UInt8>?, Int
    ) -> Bool
    private typealias TerminalHasExited = @convention(c) (OpaquePointer?) -> Bool

    static let supportedABIVersion: UInt32 = 1
    static let shared = loadDefault()

    private let handle: UnsafeMutableRawPointer
    private let connectFunction: Connect
    private let setClientUpdateCallbackFunction: SetUpdateCallback
    private let requestFunction: Request
    private let stringFreeFunction: StringFree
    private let attachTerminalFunction: AttachTerminal
    private let copyClientDiagnosticsFunction: CopyString
    private let disconnectClientFunction: Disconnect
    private let setTerminalUpdateCallbackFunction: SetUpdateCallback
    private let terminalSendFunction: TerminalSend
    private let terminalSendKeyFunction: TerminalSendKey
    private let terminalPasteFunction: TerminalSend
    private let terminalResizeFunction: TerminalResize
    private let copyRenderEventFunction: CopyRenderEvent
    private let copyTerminalDiagnosticsFunction: CopyString
    private let terminalHasExitedFunction: TerminalHasExited
    private let disconnectTerminalFunction: Disconnect

    private init(
        handle: UnsafeMutableRawPointer,
        connect: @escaping Connect,
        setClientUpdateCallback: @escaping SetUpdateCallback,
        request: @escaping Request,
        stringFree: @escaping StringFree,
        attachTerminal: @escaping AttachTerminal,
        copyClientDiagnostics: @escaping CopyString,
        disconnectClient: @escaping Disconnect,
        setTerminalUpdateCallback: @escaping SetUpdateCallback,
        terminalSend: @escaping TerminalSend,
        terminalSendKey: @escaping TerminalSendKey,
        terminalPaste: @escaping TerminalSend,
        terminalResize: @escaping TerminalResize,
        copyRenderEvent: @escaping CopyRenderEvent,
        copyTerminalDiagnostics: @escaping CopyString,
        terminalHasExited: @escaping TerminalHasExited,
        disconnectTerminal: @escaping Disconnect
    ) {
        self.handle = handle
        connectFunction = connect
        setClientUpdateCallbackFunction = setClientUpdateCallback
        requestFunction = request
        stringFreeFunction = stringFree
        attachTerminalFunction = attachTerminal
        copyClientDiagnosticsFunction = copyClientDiagnostics
        disconnectClientFunction = disconnectClient
        setTerminalUpdateCallbackFunction = setTerminalUpdateCallback
        terminalSendFunction = terminalSend
        terminalSendKeyFunction = terminalSendKey
        terminalPasteFunction = terminalPaste
        terminalResizeFunction = terminalResize
        copyRenderEventFunction = copyRenderEvent
        copyTerminalDiagnosticsFunction = copyTerminalDiagnostics
        terminalHasExitedFunction = terminalHasExited
        disconnectTerminalFunction = disconnectTerminal
    }

    deinit {
        dlclose(handle)
    }

    static var defaultLibraryPaths: [String] {
        var paths: [String] = []
#if DEBUG
        if let environmentPath = ProcessInfo.processInfo.environment["CMUX_TUI_CLIENT_LIB"],
           !environmentPath.isEmpty {
            paths.append(environmentPath)
        }
#endif
        if let privateFrameworksPath = Bundle.main.privateFrameworksPath {
            paths.append(
                URL(fileURLWithPath: privateFrameworksPath)
                    .appendingPathComponent(libraryFileName)
                    .path
            )
        }

#if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relativePath in [
            "cmux-tui/target/release",
            "cmux-tui/target/aarch64-apple-darwin/release",
            "cmux-tui/target/x86_64-apple-darwin/release",
        ] {
            paths.append(
                sourceRoot.appendingPathComponent(relativePath)
                    .appendingPathComponent(libraryFileName)
                    .path
            )
        }
#endif
        return paths
    }

    private static func loadDefault() -> CmuxTUIClientLibrary? {
        assertCompatibleLayout()
        for path in defaultLibraryPaths where FileManager.default.fileExists(atPath: path) {
            if let library = load(path: path) {
                return library
            }
        }
        return nil
    }

    private static func load(path: String) -> CmuxTUIClientLibrary? {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let abiVersion = symbol("cmux_frontend_client_abi_version", from: handle, as: ABIVersion.self),
              abiVersion() == supportedABIVersion,
              let connect = symbol("cmux_frontend_client_connect_with_timeout", from: handle, as: Connect.self),
              let setClientUpdateCallback = symbol("cmux_frontend_client_set_update_callback", from: handle, as: SetUpdateCallback.self),
              let request = symbol("cmux_frontend_client_request", from: handle, as: Request.self),
              let stringFree = symbol("cmux_frontend_string_free", from: handle, as: StringFree.self),
              let attachTerminal = symbol("cmux_frontend_client_attach_terminal", from: handle, as: AttachTerminal.self),
              let copyClientDiagnostics = symbol("cmux_frontend_client_copy_diagnostics", from: handle, as: CopyString.self),
              let disconnectClient = symbol("cmux_frontend_client_disconnect", from: handle, as: Disconnect.self),
              let setTerminalUpdateCallback = symbol("cmux_frontend_terminal_set_update_callback", from: handle, as: SetUpdateCallback.self),
              let terminalSend = symbol("cmux_frontend_terminal_send", from: handle, as: TerminalSend.self),
              let terminalSendKey = symbol("cmux_frontend_terminal_send_key", from: handle, as: TerminalSendKey.self),
              let terminalPaste = symbol("cmux_frontend_terminal_paste", from: handle, as: TerminalSend.self),
              let terminalResize = symbol("cmux_frontend_terminal_resize", from: handle, as: TerminalResize.self),
              let copyRenderEvent = symbol("cmux_frontend_terminal_copy_next_render_event", from: handle, as: CopyRenderEvent.self),
              let copyTerminalDiagnostics = symbol("cmux_frontend_terminal_copy_diagnostics", from: handle, as: CopyString.self),
              let terminalHasExited = symbol("cmux_frontend_terminal_has_exited", from: handle, as: TerminalHasExited.self),
              let disconnectTerminal = symbol("cmux_frontend_terminal_disconnect", from: handle, as: Disconnect.self)
        else {
            dlclose(handle)
            return nil
        }
        return CmuxTUIClientLibrary(
            handle: handle,
            connect: connect,
            setClientUpdateCallback: setClientUpdateCallback,
            request: request,
            stringFree: stringFree,
            attachTerminal: attachTerminal,
            copyClientDiagnostics: copyClientDiagnostics,
            disconnectClient: disconnectClient,
            setTerminalUpdateCallback: setTerminalUpdateCallback,
            terminalSend: terminalSend,
            terminalSendKey: terminalSendKey,
            terminalPaste: terminalPaste,
            terminalResize: terminalResize,
            copyRenderEvent: copyRenderEvent,
            copyTerminalDiagnostics: copyTerminalDiagnostics,
            terminalHasExited: terminalHasExited,
            disconnectTerminal: disconnectTerminal
        )
    }

    private static func symbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer,
        as _: T.Type
    ) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func assertCompatibleLayout() {
        precondition(MemoryLayout<Int>.size == 8)
        precondition(MemoryLayout<CmuxTUIRenderEventDescriptor>.size == 16)
        precondition(MemoryLayout<CmuxTUIRenderEventDescriptor>.stride == 16)
        precondition(MemoryLayout<CmuxTUIRenderEventDescriptor>.alignment == 8)
        precondition(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.kind) == 0)
        precondition(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.columns) == 4)
        precondition(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.rows) == 6)
        precondition(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.payloadLength) == 8)
    }

    func connect(
        invitation: String,
        errorBuffer: inout [CChar],
        timeoutMilliseconds: UInt64
    ) -> OpaquePointer? {
        invitation.withCString {
            connectFunction($0, &errorBuffer, errorBuffer.count, timeoutMilliseconds)
        }
    }

    func setClientUpdateCallback(
        _ client: OpaquePointer?,
        callback: CmuxTUIUpdateCallback?,
        context: UnsafeMutableRawPointer?
    ) {
        setClientUpdateCallbackFunction(client, callback, context)
    }

    func request(
        client: OpaquePointer?,
        operation: String,
        paramsJSON: String,
        mutation: Bool,
        errorBuffer: inout [CChar]
    ) -> UnsafeMutablePointer<CChar>? {
        operation.withCString { operationPointer in
            paramsJSON.withCString { paramsPointer in
                requestFunction(
                    client,
                    operationPointer,
                    paramsPointer,
                    mutation,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }
    }

    func free(string: UnsafeMutablePointer<CChar>?) {
        stringFreeFunction(string)
    }

    func attachTerminal(
        client: OpaquePointer?,
        publicID: String,
        errorBuffer: inout [CChar],
        timeoutMilliseconds: UInt64
    ) -> OpaquePointer? {
        publicID.withCString {
            attachTerminalFunction(
                client,
                $0,
                &errorBuffer,
                errorBuffer.count,
                timeoutMilliseconds
            )
        }
    }

    func clientDiagnostics(_ client: OpaquePointer?) -> String {
        copyString { copyClientDiagnosticsFunction(client, $0, $1) }
    }

    func disconnectClient(_ client: OpaquePointer?) {
        disconnectClientFunction(client)
    }

    func setTerminalUpdateCallback(
        _ terminal: OpaquePointer?,
        callback: CmuxTUIUpdateCallback?,
        context: UnsafeMutableRawPointer?
    ) {
        setTerminalUpdateCallbackFunction(terminal, callback, context)
    }

    func send(_ data: Data, terminal: OpaquePointer?) -> Bool {
        data.withUnsafeBytes {
            terminalSendFunction(
                terminal,
                $0.bindMemory(to: UInt8.self).baseAddress,
                $0.count
            )
        }
    }

    func sendKey(_ chord: String, repeat isRepeat: Bool, terminal: OpaquePointer?) -> Bool {
        chord.withCString { terminalSendKeyFunction(terminal, $0, isRepeat) }
    }

    func paste(_ data: Data, terminal: OpaquePointer?) -> Bool {
        data.withUnsafeBytes {
            terminalPasteFunction(
                terminal,
                $0.bindMemory(to: UInt8.self).baseAddress,
                $0.count
            )
        }
    }

    func resize(_ geometry: CmuxTUITerminalGeometry, terminal: OpaquePointer?) -> Bool {
        terminalResizeFunction(terminal, geometry.columns, geometry.rows)
    }

    func copyNextRenderEvent(
        terminal: OpaquePointer?,
        descriptor: inout CmuxTUIRenderEventDescriptor,
        buffer: UnsafeMutablePointer<UInt8>?,
        capacity: Int
    ) -> Bool {
        withUnsafeMutablePointer(to: &descriptor) {
            copyRenderEventFunction(
                terminal,
                UnsafeMutableRawPointer($0),
                buffer,
                capacity
            )
        }
    }

    func terminalDiagnostics(_ terminal: OpaquePointer?) -> String {
        copyString { copyTerminalDiagnosticsFunction(terminal, $0, $1) }
    }

    func terminalHasExited(_ terminal: OpaquePointer?) -> Bool {
        terminalHasExitedFunction(terminal)
    }

    func disconnectTerminal(_ terminal: OpaquePointer?) {
        disconnectTerminalFunction(terminal)
    }

    private func copyString(
        _ copy: (_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int
    ) -> String {
        copyBoundedCString(copy) ?? ""
    }

    private static let libraryFileName = "libcmux_terminal_client.dylib"
}
