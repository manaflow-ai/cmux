import Foundation
import Network

extension CloudMachineLinkManager {
    /// Selects a working family using the same SOCKS connector as port forwards.
    /// The probe sends no daemon request and closes its stream before the real
    /// encrypted link starts. A failed probe keeps the existing bounded connect
    /// behavior, so a daemon that is still starting can recover normally.
    func resolvedPrivateRoute(
        machineID: String,
        through hub: CloudWireGuardHub.Ready,
        fallbackRoute: String? = nil,
        addresses freshAddresses: [String] = []
    ) async throws -> String {
        guard let primaryRoute = fallbackRoute ?? privateRoute(for: machineID) else {
            throw ManagerError.privateRouteRequired(machineID)
        }
        let candidates = freshAddresses.isEmpty ? privateAddresses(for: machineID) : freshAddresses
        let addresses = candidates.filter {
            CloudWireGuardHub.routesHost($0, enrolledRoutes: hub.routes)
        }
        guard addresses.count > 1, let primary = addresses.first else { return primaryRoute }
        let connected: CloudHubConnector.Connected
        do {
            connected = try await CloudHubConnector().connect(
                endpoint: .unix(path: hub.socketPath),
                target: CloudPortForwardTarget(host: primary, port: 1337, fallbackHosts: Array(addresses.dropFirst())),
                queue: DispatchQueue.global(qos: .userInitiated)
            )
        } catch {
            try Task.checkCancellation()
            return primaryRoute
        }
        connected.connection.cancel()
        let host = connected.host.contains(":") ? "[\(connected.host)]" : connected.host
        return "ws://\(host):1337/v1/link"
    }
}
