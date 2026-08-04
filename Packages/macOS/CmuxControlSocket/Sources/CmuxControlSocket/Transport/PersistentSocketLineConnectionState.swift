internal import Darwin
internal import Foundation

struct PersistentSocketLineConnectionState: Sendable {
    let socket: Int32
    let path: String
    var timeout: TimeInterval
    let peerProcessID: pid_t?
    var responseBuffer = Data()
}
