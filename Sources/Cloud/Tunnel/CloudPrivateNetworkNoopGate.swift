import Foundation

struct CloudPrivateNetworkNoopGate: CloudPrivateNetworkGate {
    func requirePrivateNetworkUse(_ use: CloudPrivateNetworkUse) async throws {}
}
