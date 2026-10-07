/// Listening TCP ports of given processes that this Mac's loopback reaches.
public protocol ListeningPortScanner: Sendable {
    func listeningPorts(of pids: [Int32]) -> [Int32: [UInt16]]
}
