import Foundation

/// Swift side of the cmux remote client.
///
/// Every call into the C ABI blocks, so this is an actor: the handle is used
/// from one task at a time and never from the main thread. Nothing here parses
/// the daemon protocol; that all happens in Rust.
actor RemoteClient {
    enum PathMode: UInt32 {
        case auto = 0
        case directOnly = 1
        case relayOnly = 2
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?

    /// Connect and authenticate. On a first enrollment this waits for the owner
    /// to approve the device on the daemon's host, so it can take a while.
    func connect(invitation: String, deviceName: String, pathMode: PathMode) throws {
        disconnect()
        var error: UnsafeMutablePointer<CChar>?
        let handle = invitation.withCString { invite in
            deviceName.withCString { device in
                cmux_mobile_connect(invite, device, pathMode.rawValue, &error)
            }
        }
        guard let handle else {
            throw Failure(message: takeString(error) ?? "the connection failed for an unreported reason")
        }
        self.handle = handle
    }

    func openTerminal(root: String, cols: UInt16, rows: UInt16) throws {
        let handle = try requireHandle()
        let code = root.withCString {
            cmux_mobile_open_terminal(handle, $0, cols, rows)
        }
        try check(code, handle: handle)
    }

    func write(_ data: Data) throws {
        let handle = try requireHandle()
        let code = data.withUnsafeBytes { bytes in
            cmux_mobile_write(handle, bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        try check(code, handle: handle)
    }

    func write(_ text: String) throws {
        try write(Data(text.utf8))
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        let handle = try requireHandle()
        try check(cmux_mobile_resize(handle, cols, rows), handle: handle)
    }

    /// Wait for terminal output. Returns nil on timeout, which for an idle
    /// shell is the normal case and not an error.
    func readOutput(timeout: Duration = .milliseconds(250)) -> Data? {
        guard let handle else { return nil }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var produced = 0
        let milliseconds = UInt32(timeout.components.seconds * 1000
            + timeout.components.attoseconds / 1_000_000_000_000_000)
        let code = buffer.withUnsafeMutableBufferPointer { pointer in
            cmux_mobile_read(handle, pointer.baseAddress, pointer.count, &produced, milliseconds)
        }
        guard code == CMUX_MOBILE_OK, produced > 0 else { return nil }
        return Data(buffer[0..<produced])
    }

    /// The rendered terminal, as the daemon currently models it.
    func terminal() -> TerminalSnapshot? {
        guard let handle, let json = takeString(cmux_mobile_terminal_json(handle)) else {
            return nil
        }
        return try? JSONDecoder().decode(TerminalSnapshot.self, from: Data(json.utf8))
    }

    /// Connection diagnostics, including whether iroh chose a direct or relayed
    /// path. Credential-free, so it is safe to show and to log.
    func connection() -> ConnectionSnapshot? {
        guard let handle, let json = takeString(cmux_mobile_snapshot_json(handle)) else {
            return nil
        }
        return try? JSONDecoder().decode(ConnectionSnapshot.self, from: Data(json.utf8))
    }

    func disconnect() {
        guard let handle else { return }
        self.handle = nil
        cmux_mobile_free(handle)
    }

    deinit {
        if let handle {
            cmux_mobile_free(handle)
        }
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw Failure(message: "not connected") }
        return handle
    }

    private func check(_ code: Int32, handle: OpaquePointer) throws {
        guard code != CMUX_MOBILE_OK else { return }
        let detail = takeString(cmux_mobile_last_error(handle))
        throw Failure(message: detail ?? "the call failed with code \(code)")
    }

    /// Copy a string out of the library and release the original.
    private func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { cmux_mobile_string_free(pointer) }
        return String(cString: pointer)
    }
}

// MARK: - Wire types

/// The daemon's terminal model. Mirrors `ProcessTerminalSnapshot`.
struct TerminalSnapshot: Decodable {
    struct Size: Decodable {
        let cols: UInt16
        let rows: UInt16
    }

    struct Color: Decodable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    struct StyledRun: Decodable {
        let text: String
        let fg: Color?
        let bg: Color?
        let attrs: UInt16

        var isBold: Bool { attrs & 0x1 != 0 }
        var isItalic: Bool { attrs & 0x2 != 0 }
    }

    struct Row: Decodable {
        let row: UInt16
        let runs: [StyledRun]
    }

    struct Cursor: Decodable {
        let x: UInt16
        let y: UInt16
        let visible: Bool
    }

    let size: Size
    let rows: [Row]
    let cursor: Cursor
    let defaultFg: Color
    let defaultBg: Color
    let throughSequence: UInt64

    enum CodingKeys: String, CodingKey {
        case size, rows, cursor
        case defaultFg = "default_fg"
        case defaultBg = "default_bg"
        case throughSequence = "through_sequence"
    }
}

/// Mirrors the JSON `cmux_mobile_snapshot_json` produces.
struct ConnectionSnapshot: Decodable {
    let generation: UInt64
    let state: String
    let provider: String
    let route: String
    /// "Direct" or "Relay" once iroh has settled on a path.
    let path: String?

    var pathLabel: String { path ?? "selecting" }
}
