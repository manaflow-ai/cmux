public import CmuxNextAgentPane
public import CmuxNextCloud
import Foundation

extension CloudAgentCredentials {
    /// A Cloud chat's model credential, read as the person from this Mac's acpmux at `environment`
    /// (``AcpmuxEnvironment/connectionCredential(id:)``, cmux-tui/docs/model-connections.md Revision 2);
    /// no acpmux, no person line or no reply is ``Failure/unavailable(connection:)``.
    public static func acpmuxRead(environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> Read {
        { id in
            guard let reply = await environment()?.connectionCredential(id: id) else { throw Failure.unavailable(connection: id) }
            return reply
        }
    }
}
