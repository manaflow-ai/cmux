import Foundation

/// The user-facing endpoint for a Cloud VM port. `url` is the address a local
/// browser can load; when it is a loopback forward, `remotePort` remains the
/// VM service port and `localPort` is the listener on this Mac.
struct CloudPortLink: Equatable, Sendable {
    let remotePort: Int
    let url: String
    let privateURL: String?
    let localPort: UInt16?
}
