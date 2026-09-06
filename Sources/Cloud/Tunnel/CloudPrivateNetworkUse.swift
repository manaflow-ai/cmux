import Foundation

struct CloudPrivateNetworkUse: Sendable, Equatable {
    let machineID: String
    let purpose: CloudPrivateNetworkPurpose
}

/// The gate for builds and tests that do not manage a tunnel: dial straight
/// away, exactly as before the app-managed tunnel existed.
