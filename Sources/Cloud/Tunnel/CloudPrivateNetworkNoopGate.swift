import Foundation

struct CloudPrivateNetworkNoopGate: CloudPrivateNetworkGate {
    func prepareForPrivateNetworkUse(_ use: CloudPrivateNetworkUse) async {}
}
