import Foundation

/// The byte channel an ``SFTPClient`` speaks over: an `sftp` subsystem
/// session in production (``SSHSessionChannel``), an in-memory server in
/// tests. `events` must deliver `stdout` in order and finish after `.closed`.
public protocol SFTPChannel: Sendable {
    var events: AsyncStream<SSHSessionEvent> { get }
    func write(_ data: Data) async throws
    func close() async
}

extension SSHSessionChannel: SFTPChannel {}
