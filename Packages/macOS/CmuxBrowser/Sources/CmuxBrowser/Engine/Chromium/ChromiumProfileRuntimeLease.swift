import Foundation

/// One page target leased from a profile-scoped Chromium process.
struct ChromiumProfileRuntimeLease: Sendable {
    let connection: CDPConnection
    let targetID: String
    let sessionID: String
    let processIdentifier: Int32?
}
