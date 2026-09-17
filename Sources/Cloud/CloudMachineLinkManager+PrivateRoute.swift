import Foundation
import Network

extension CloudMachineLinkManager {
    /// Selects a working family using the same SOCKS connector as port forwards.
    /// The probe sends no daemon request and closes its stream before the real
    /// encrypted link starts. Failed probes propagate to the caller's retry policy,
    /// so the next attempt considers every current family again.
    func resolvedPrivateRoute(
        machineID: String,
        through hub: CloudWireGuardHub.Ready,
        fallbackRoute: String? = nil,
        addresses freshAddresses: [String] = []
    ) async throws -> String {
        try Task.checkCancellation()
        let freshAddresses = freshAddresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let freshFamilies = Set(freshAddresses.map { $0.contains(":") })
        // Attach can omit one family. Preserve that family from discovery, but
        // never retain an old address in a family that attach has replaced.
        let storedAddresses = privateAddresses(for: machineID).filter {
            !freshFamilies.contains($0.contains(":"))
        }
        var seen = Set<String>()
        let candidates = (freshAddresses + storedAddresses).filter { seen.insert($0).inserted }
        let addresses = candidates.filter {
            CloudWireGuardHub.routesHost($0, enrolledRoutes: hub.routes)
        }
        guard let primary = addresses.first else {
            guard candidates.isEmpty,
                  let route = fallbackRoute ?? privateRoute(for: machineID),
                  let host = IPNetworkPrefix.routeHost(route),
                  CloudWireGuardHub.routesHost(host, enrolledRoutes: hub.routes) else {
                throw ManagerError.privateRouteRequired(machineID)
            }
            return route
        }
        // Fresh discovery or the enrolled routes can leave a single candidate.
        // Use it directly rather than returning an older address-family route.
        guard addresses.count > 1 else {
            let host = primary.contains(":") ? "[\(primary)]" : primary
            return "ws://\(host):1337/v1/link"
        }
        let connected = try await CloudHubConnector().connect(
            endpoint: .unix(path: hub.socketPath),
            target: CloudPortForwardTarget(host: primary, port: 1337, fallbackHosts: Array(addresses.dropFirst())),
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        connected.connection.cancel()
        let host = connected.host.contains(":") ? "[\(connected.host)]" : connected.host
        return "ws://\(host):1337/v1/link"
    }
}
