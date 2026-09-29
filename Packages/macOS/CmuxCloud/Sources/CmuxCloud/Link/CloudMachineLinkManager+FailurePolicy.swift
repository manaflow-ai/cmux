import Foundation

extension CloudMachineLinkManager {
    /// Only a typed missing-machine response stops automatic reconnect.
    nonisolated static func shouldStopAutomaticReconnect(_ error: Error) -> Bool {
        (error as? VMClientError)?.cloudHTTPError?.isMachineNotFound == true
    }
}
