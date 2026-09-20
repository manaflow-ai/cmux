import Foundation

/// A protocol-12 cmux frontend client over an authenticated SSH exec stream.
///
/// The remote command is `cmux-tui relay`, so iOS ships no cmux-tui binary.
/// SSH authenticates the carrier and the client validates the cmux identify
/// response before sending any workspace command. Requests are intentionally
/// serialized because the compatibility stream has one ordered JSON-lines
/// channel; create one client per remote session.
public actor MobileRemoteCmuxProtocolClient {
    /// Maximum accepted JSON line, matching the remote protocol budget.
    public static let maximumFrameBytes = 16 * 1024 * 1024

    private let session: any MobileRemoteSSHSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let maximumFrameBytes: Int
    private let reader: MobileRemoteCmuxLineReader
    private var nextID = 1
    private var inFlight = false
    private var closed = false
    private(set) var protocolVersion: Int?

    /// Creates a client over an already account-gated, host-approved SSH session.
    /// - Parameters:
    ///   - session: An exec session running the cmux relay command.
    ///   - maximumFrameBytes: Per-line bound; never exceed the protocol maximum.
    public init(
        session: any MobileRemoteSSHSession,
        maximumFrameBytes: Int = MobileRemoteCmuxProtocolClient.maximumFrameBytes
    ) {
        self.session = session
        self.maximumFrameBytes = min(maximumFrameBytes, Self.maximumFrameBytes)
        let reader = MobileRemoteCmuxLineReader()
        self.reader = reader
        Task { await reader.start(stream: session.output()) }
    }

    /// Performs identify and capability negotiation.
    /// - Throws: Protocol, compatibility, transport, or server errors.
    public func connect() async throws {
        let identity = try await request(command: "identify")
        guard let data = identity.objectValue,
              data["app"]?.stringValue == "cmux-tui",
              data["protocol"]?.integerValue == 12 else {
            await close()
            throw MobileRemoteCmuxProtocolError.incompatibleServer
        }
        protocolVersion = 12
        _ = try await request(
            command: "set-client-info",
            parameters: ["kind": .string("frontend"), "capabilities": .array([])]
        )
    }

    /// Lists the authoritative workspace tree.
    /// - Returns: The server's protocol response object.
    /// - Throws: Protocol or server errors.
    public func listWorkspaces() async throws -> MobileRemoteCmuxJSONValue {
        try await request(command: "list-workspaces")
    }

    /// Attaches a surface in render mode for a native terminal view.
    /// - Parameter surface: Existing cmux surface identifier.
    /// - Returns: The attach acknowledgement; render events follow on the stream.
    /// - Throws: Protocol or server errors.
    public func attachSurface(surface: Int) async throws -> MobileRemoteCmuxJSONValue {
        try await request(
            command: "attach-surface",
            parameters: ["surface": .number(String(surface)), "mode": .string("render")]
        )
    }

    /// Sends one validated protocol command for an endpoint-specific feature.
    /// - Parameters:
    ///   - command: A cmux protocol command name, never shell text.
    ///   - parameters: JSON request fields excluding `id` and `cmd`.
    /// - Returns: The successful `data` value.
    /// - Throws: Protocol, concurrent-request, or server errors.
    public func request(
        command: String,
        parameters: [String: MobileRemoteCmuxJSONValue] = [:]
    ) async throws -> MobileRemoteCmuxJSONValue {
        guard !closed else { throw MobileRemoteCmuxProtocolError.closed }
        guard !inFlight else { throw MobileRemoteCmuxProtocolError.concurrentRequest }
        guard !command.isEmpty, command.utf8.count <= 128,
              command.utf8.allSatisfy({ $0 == 45 || $0 == 95 || ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }) else {
            throw MobileRemoteCmuxProtocolError.malformedFrame
        }
        inFlight = true
        defer { inFlight = false }
        let id = nextID
        nextID += 1
        var frame: [String: MobileRemoteCmuxJSONValue] = [
            "id": .number(String(id)), "cmd": .string(command)
        ]
        frame.merge(parameters, uniquingKeysWith: { current, _ in current })
        var encoded = try encoder.encode(MobileRemoteCmuxJSONValue.object(frame))
        encoded.append(0x0A)
        guard encoded.count <= maximumFrameBytes else { throw MobileRemoteCmuxProtocolError.frameTooLarge }
        do {
            try await session.sendInput(encoded)
            while true {
                let line = try await reader.nextLine(maximumBytes: maximumFrameBytes)
                let response: MobileRemoteCmuxJSONValue
                do { response = try decoder.decode(MobileRemoteCmuxJSONValue.self, from: line) }
                catch { throw MobileRemoteCmuxProtocolError.malformedFrame }
                guard let object = response.objectValue,
                      object["id"]?.integerValue == id else {
                    throw MobileRemoteCmuxProtocolError.responseIDMismatch
                }
                guard object["ok"]?.booleanValue == true else {
                    let message = object["error"]?.stringValue ?? "remote command failed"
                    throw MobileRemoteCmuxProtocolError.server(message)
                }
                return object["data"] ?? .object([:])
            }
        } catch let error as MobileRemoteCmuxProtocolError {
            throw error
        } catch {
            throw MobileRemoteCmuxProtocolError.server("transport failure")
        }
    }

    /// Closes the exec stream and releases the underlying SSH channel.
    public func close() async {
        guard !closed else { return }
        closed = true
        await session.close()
    }

}
