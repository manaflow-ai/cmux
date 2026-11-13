public import CmuxNextAgentPane
public import CmuxNextCloud
import Foundation

extension CloudAgentCredentials {
    /// A Cloud chat's model credential, read as the person from this Mac's acpmux at `environment`
    /// (`_acpmux/connections/credential {id}`, cmux-tui/docs/model-connections.md Revision 2); no
    /// acpmux, no person line or no reply is ``Failure/unavailable(connection:)``.
    public static func acpmuxRead(environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> Read {
        { id in
            guard let environment = environment(), let line = await AcpmuxPersonLine.open(environment) else { throw Failure.unavailable(connection: id) }
            defer { line.close() }
            guard line.isPerson, let reply = await line.call("_acpmux/connections/credential", ["id": id]) else { throw Failure.unavailable(connection: id) }
            return try JSONSerialization.data(withJSONObject: reply)
        }
    }
}
