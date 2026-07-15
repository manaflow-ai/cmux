import Foundation

/// The browser-level connection shared by every page target in one profile.
struct ChromiumProfileRuntimeConnection: Sendable {
    let connection: CDPConnection
    let processIdentifier: Int32?
}
