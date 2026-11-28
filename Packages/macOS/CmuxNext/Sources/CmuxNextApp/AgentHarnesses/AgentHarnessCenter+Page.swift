import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Settings > Agents' gestures (`cmux.settings.agents.run`): the same operations the
/// `agent.harness.*` actions run. A daemon refusal answers `cmux.agents.<code>` with the daemon's
/// text (`cmux.agents.unsupported` for an acpmux without the operations), so the page can say why.
extension AgentHarnessCenter {
    func runPage(_ params: JSONValue) async throws -> JSONValue {
        let id = params["id"]?.stringValue ?? ""
        do {
            switch params["action"]?.stringValue {
            case "refresh":
                await refresh()
                return .object([:])
            case "registry":
                return try await loadRegistry(refresh: params["refresh"]?.boolValue ?? false)
            case "add":
                var request = AgentHarnessAddRequest()
                request.id = params["id"]?.stringValue
                request.displayName = params["displayName"]?.stringValue
                request.command = params["command"]?.stringValue
                request.args = params["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
                request.protocolName = params["protocol"]?.stringValue
                request.registry = params["registry"]?.stringValue
                request.envKeys = params["envKeys"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard request.isComplete else { throw PageError.invalidParams("nothing to start") }
                return try await add(request)
            case "remove" where !id.isEmpty:
                return try await remove(id: id)
            case "restore":
                guard let backup = params["backup"]?.stringValue ?? lastRemovedBackup else {
                    throw PageError.invalidParams("no backup")
                }
                return try await restore(backup: backup)
            case "doctor" where !id.isEmpty:
                return try await doctor(id: id, noPrompt: params["noPrompt"]?.boolValue ?? false)
            default:
                throw PageError.invalidParams("unknown agents action")
            }
        } catch let error as PageError {
            throw error
        } catch {
            throw PageError(code: "cmux.agents.\(Self.code(error))", message: Self.text(error))
        }
    }

    /// The page's error code: the daemon's error id (`harness.exists` -> `exists`), `unsupported`,
    /// `unavailable` (no daemon), else `failed`.
    static func code(_ error: any Error) -> String {
        switch error {
        case AgentHarnessFailure.unsupported: return "unsupported"
        case AgentHarnessFailure.noDaemon: return "unavailable"
        case let rpc as AcpmuxRPCError:
            return rpc.name.map { String($0.split(separator: ".").last ?? Substring($0)) } ?? "failed"
        default: return "failed"
        }
    }
}
