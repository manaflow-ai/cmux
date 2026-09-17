import Foundation

/// Identity for a browser access model. The loopback forward itself remains
/// keyed only by machine and port; scheme belongs to the browser route because
/// the raw relay supports HTTP but cannot carry HTTPS certificate identity.
struct CloudPortAccessKey: Hashable {
    let machineID: String
    let port: Int
    let scheme: String
}
