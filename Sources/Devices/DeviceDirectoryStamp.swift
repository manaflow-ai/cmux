import Foundation

/// The revision and issue time of the complete v2 directory this Mac holds.
/// A new revision is the control plane's own signal that permissions may
/// have changed, so it is what retries a host's refusal.
struct DeviceDirectoryStamp: Equatable, Sendable {
    let revision: Int
    let issuedAt: Int
}
