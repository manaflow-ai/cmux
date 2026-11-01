public import Foundation

/// Adapter 1 (contract 2.3, C13b): the Cloud app server's
/// `cloud.machine.connect` answers `{machine, carrier, generation, state:
/// "up", socket, vm_kind?}`; `socket` is the carrier's local socket in an owner-only
/// directory, and each connection to it is one dial of the machine's daemon.
/// `vm_kind` is the Cloud API's owner answer for this connect: only the exact
/// value `owner` says the signed-in caller owns the machine.
/// The app connects only after ``CloudLinkSocketPolicy`` accepts the path.
public struct CloudConnectOpResolver: CloudLinkResolver {
    public static let connectOp = "cloud.machine.connect"
    public static let disconnectOp = "cloud.machine.disconnect"
    /// `first-party-apps/cloud/server/src/link/ops.rs` error codes.
    static let revokedCode = "cmux.cloud.link_revoked"
    static let downCodes: Set<String> = ["cmux.cloud.link_down"]
    static let helperCode = "cmux.cloud.link_unavailable"

    private let run: CloudAppOpRunner
    private let check: @Sendable (String) throws -> Void

    public init(run: @escaping CloudAppOpRunner) {
        self.init(run: run, check: { try CloudLinkSocketPolicy.check($0) })
    }

    init(run: @escaping CloudAppOpRunner, check: @escaping @Sendable (String) throws -> Void) {
        self.run = run
        self.check = check
    }

    private struct Answer: Decodable {
        var machine: String
        var state: String
        var generation: UInt64?
        var socket: String?
        /// `vm_kind` when it is a string; any other JSON type reads as absent (not the owner),
        /// never as a refused connect.
        var vmKind: String?

        enum CodingKeys: String, CodingKey {
            case machine, state, generation, socket
            case vmKind = "vm_kind"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            machine = try c.decode(String.self, forKey: .machine)
            state = try c.decode(String.self, forKey: .state)
            generation = try c.decodeIfPresent(UInt64.self, forKey: .generation)
            socket = try c.decodeIfPresent(String.self, forKey: .socket)
            vmKind = try? c.decodeIfPresent(String.self, forKey: .vmKind)
        }
    }

    public func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        let data: Data
        do {
            data = try await run(Self.connectOp, ["machine": key.machine], intent, origin)
        } catch let error as CloudAppOpError {
            throw Self.linkError(error)
        } catch let error as CloudLinkError {
            throw error
        } catch {
            throw CloudLinkError.failed(code: "", message: String(describing: error))
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw CloudLinkError.invalidAnswer("not a carrier")
        }
        guard answer.machine == key.machine else { throw CloudLinkError.invalidAnswer("carrier of another machine") }
        guard answer.state == "up" else { throw CloudLinkError.notUp(state: answer.state) }
        guard let socket = answer.socket, !socket.isEmpty else { throw CloudLinkError.invalidAnswer("no socket") }
        try check(socket)
        return CloudLinkSocket(key: key, path: socket, generation: answer.generation, callerOwnsVM: answer.vmKind == "owner",
                               callerIsTeammate: answer.vmKind == "team")
    }

    /// `cloud.machine.disconnect` ends the carrier. A failure leaves nothing
    /// to repair here: the app server ends every link when it stops.
    public func close(_ key: CloudLinkKey) async {
        _ = try? await run(Self.disconnectOp, ["machine": key.machine], UUID().uuidString, .script)
    }

    static func linkError(_ error: CloudAppOpError) -> CloudLinkError {
        if error.code == revokedCode { return .revoked(reason: error.message) }
        if error.code == helperCode { return .helperNotRunning(reason: error.message) }
        if downCodes.contains(error.code) { return .disconnected(reason: error.message) }
        return .failed(code: error.code, message: error.message)
    }
}
