public import CmuxMobileHost
public import CmuxMobileWire
public import CmuxNextDaemon
import Foundation

/// `MobileGitReader` over the session host's git reads (`GitResourceClient`,
/// 30 s deadline; c13-viewers.md 3). `not_a_repository` refusals become
/// `git.not_a_repo`; the host maps every other failure to `git.failed`.
public struct DaemonGitReader: MobileGitReader {
    private let read: @Sendable (_ operation: String, _ params: [String: CmuxNextDaemon.JSONValue]) async throws -> CmuxNextDaemon.JSONValue

    public init(read: @escaping @Sendable (_ operation: String, _ params: [String: CmuxNextDaemon.JSONValue]) async throws
        -> CmuxNextDaemon.JSONValue) {
        self.read = read
    }

    public init(connection: DaemonConnection) {
        self.init { operation, params in try await GitResourceClient(connection: connection).read(operation, params: params) }
    }

    public func read(_ operation: String, params: CmuxMobileWire.JSONValue) async throws -> CmuxMobileWire.JSONValue {
        let converted = try JSONDecoder().decode([String: CmuxNextDaemon.JSONValue].self, from: JSONEncoder().encode(params))
        let result: CmuxNextDaemon.JSONValue
        do {
            result = try await read(operation, converted)
        } catch let DaemonError.command(_, message, code, details, _) where code == "operation.failed"
            && details?["extra"]?["code"]?.stringValue == "not_a_repository" {
            throw MobileDaemonError(code: "git.not_a_repo", message: message)
        }
        return try JSONDecoder().decode(CmuxMobileWire.JSONValue.self, from: JSONEncoder().encode(result))
    }
}
