import Foundation

/// The revision and issue time of the complete v2 directory this Mac holds.
/// A new revision is the control plane's own signal that permissions may
/// have changed, so it is what retries a host's refusal.
struct DeviceDirectoryStamp: Equatable, Sendable {
    let revision: Int
    let issuedAt: Int
    /// The per-user account directory revision, when one applies. Its own
    /// advance is the same retry signal for a Mac reached across teams.
    var accountRevision: Int? = nil

    /// Whether either directory advanced since `previous`.
    func advanced(since previous: DeviceDirectoryStamp) -> Bool {
        if revision > previous.revision { return true }
        guard let accountRevision else { return false }
        return accountRevision > (previous.accountRevision ?? -1)
    }
}
