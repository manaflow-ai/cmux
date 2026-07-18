internal import Foundation

/// A single granted native-SSH connection attempt for one endpoint.
struct NativeSSHConnectionPermit: Sendable {
    let key: NativeSSHConnectionKey
    let token: UUID
}
