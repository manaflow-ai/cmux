import CmuxRemoteDaemon
import Foundation
@testable import CmuxRemoteWorkspace

/// Daemon stream fake for proxy session tests: records every opened target
/// and answers stream writes by echoing them, or with one canned reply and
/// EOF when `cannedReply` is set.
final class ProxyStreamTestRPCClient: RemoteDaemonTunnelRPCClient, @unchecked Sendable {
    private struct Attachment: @unchecked Sendable {
        let queue: DispatchQueue
        let onEvent: (RemoteDaemonStreamEvent) -> Void
    }

    private let lock = NSLock()
    private let cannedReply: Data?
    private var _openedTargets: [String] = []
    private var attachments: [String: Attachment] = [:]
    private var repliedStreamIDs: Set<String> = []

    init(cannedReply: Data? = nil) {
        self.cannedReply = cannedReply
    }

    /// `host:port` of every stream the proxy asked the daemon to open.
    var openedTargets: [String] { lock.withLock { _openedTargets } }

    func openStream(host: String, port: Int, timeoutMs: Int) throws -> String {
        lock.withLock {
            _openedTargets.append("\(host):\(port)")
            return "stream-\(_openedTargets.count)"
        }
    }

    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (RemoteDaemonStreamEvent) -> Void
    ) throws {
        lock.withLock {
            attachments[streamID] = Attachment(queue: queue, onEvent: onEvent)
        }
    }

    func writeStream(streamID: String, data: Data) throws {
        let delivery: (Attachment, RemoteDaemonStreamEvent)? = lock.withLock {
            guard let attachment = attachments[streamID] else { return nil }
            guard let cannedReply else { return (attachment, .data(data)) }
            guard repliedStreamIDs.insert(streamID).inserted else { return nil }
            return (attachment, .eof(cannedReply))
        }
        guard let (attachment, event) = delivery else { return }
        attachment.queue.async { attachment.onEvent(event) }
    }

    func closeStream(streamID: String) {
        lock.withLock { _ = attachments.removeValue(forKey: streamID) }
    }

    func stop() {}

    func listPTY() throws -> [[String: Any]] { [] }

    func closePTY(sessionID: String, timeout: TimeInterval) throws {}

    func resizePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws {}

    func detachPTYChecked(sessionID: String, attachmentID: String, attachmentToken: String) throws {}

    func attachBridgePTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        inputSeqAck: Bool,
        queue: DispatchQueue,
        onEvent: @escaping (RemotePTYBridgeEvent) -> Void
    ) throws -> RemotePTYBridgeAttachment {
        throw NSError(domain: "test.remote.proxy", code: 2)
    }

    func writePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        data: Data,
        seq: UInt64?,
        completion: @escaping ((any Error)?) -> Void
    ) { completion(nil) }

    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}
}
