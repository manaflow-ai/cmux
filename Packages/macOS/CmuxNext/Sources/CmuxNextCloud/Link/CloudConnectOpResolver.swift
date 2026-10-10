public import Foundation

/// Adapter 1 (contract 2.3, C13b): the Cloud app server's
/// `cloud.machine.connect` answers `{machine, carrier, generation, state:
/// "up", socket}`; `socket` is the carrier's local socket in an owner-only
/// directory, and each connection to it is one dial of the machine's daemon.
/// The app connects only after ``CloudLinkSocketPolicy`` accepts the path.
public struct CloudConnectOpResolver: CloudLinkResolver {
    public static let connectOp = "cloud.machine.connect"
    public static let disconnectOp = "cloud.machine.disconnect"
    /// `first-party-apps/cloud/server/src/link/ops.rs` error codes.
    static let revokedCode = "cmux.cloud.link_revoked"
    static let downCodes: Set<String> = ["cmux.cloud.link_down", "cmux.cloud.link_unavailable"]

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
        guard answer.state == "up" else { throw CloudLinkError.invalidAnswer("carrier is \(answer.state)") }
        guard let socket = answer.socket, !socket.isEmpty else { throw CloudLinkError.invalidAnswer("no socket") }
        try check(socket)
        return CloudLinkSocket(key: key, path: socket, generation: answer.generation)
    }

    /// `cloud.machine.disconnect` ends the carrier. A failure leaves nothing
    /// to repair here: the app server ends every link when it stops.
    public func close(_ key: CloudLinkKey) async {
        _ = try? await run(Self.disconnectOp, ["machine": key.machine], UUID().uuidString, .script)
    }

    static func linkError(_ error: CloudAppOpError) -> CloudLinkError {
        if error.code == revokedCode { return .revoked(reason: error.message) }
        if downCodes.contains(error.code) { return .disconnected(reason: error.message) }
        return .failed(code: error.code, message: error.message)
    }
}
