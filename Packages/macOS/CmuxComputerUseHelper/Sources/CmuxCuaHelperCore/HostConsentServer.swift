// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import os

private let hostLogger = Logger(subsystem: "com.cmuxterm.cua", category: "host")

/// The cmux app's consent connection: a Unix socket the helper listens on
/// (path from `configure`, beside the helper socket). The app connects
/// after `ready`. Each connection is checked before the helper reads a byte:
/// the peer runs as this user (getpeereid), and its audit token
/// (LOCAL_PEERTOKEN, taken for this connection) passes `check`. A refused
/// peer gets `{"ok":false,"error":"refused","reason":"host_unverified"}`
/// and the connection closes. A verified one gets `{"ok":true}` and becomes
/// the channel's host until it closes:
///   helper -> app: {"type":"machine_consent","id":N}
///   app -> helper: {"type":"machine_consent","id":N,"ok":BOOL,"result":{...}}
///   helper -> app: {"type":"consent_refused","surface":S,"tool":T}
/// Nothing on the control pipe (stdin) can answer a consent question.
public final class HostConsentServer: Sendable {
    public let path: String
    private let channel: HostConsentChannel
    private let check: any HostCodeChecking
    private let listener = OSAllocatedUnfairLock<Int32>(initialState: -1)

    public init(path: String, channel: HostConsentChannel, check: any HostCodeChecking = CmuxAppCodeCheck()) {
        self.path = path
        self.channel = channel
        self.check = check
    }

    public func start() throws {
        let descriptor = try HelperSocketServer.listening(at: path)
        listener.withLockUnchecked { $0 = descriptor }
        HelperSocketServer.acceptLoop(descriptor, name: "cua-helper-host-accept") { [self] client in serve(client) }
    }

    public func stop() { HelperSocketServer.stop(listener, path: path) }

    /// Checks the peer, then relays answers until the connection closes.
    func serve(_ client: Int32) {
        let connection = HelperSocketServer.Connection(descriptor: client)
        let verdict: HostVerification = if let uid = HelperSocketServer.peerUID(client), uid == geteuid() {
            Self.auditToken(client).map { check.check($0) } ?? .unverified("the peer's audit token is unreadable")
        } else {
            .unverified("the peer runs as another user")
        }
        if case .unverified(let reason) = verdict {
            hostLogger.error("refused host peer; consent stays off: \(reason, privacy: .public)")
            connection.write(HelperWire.line(["ok": false, "error": "refused",
                                              "reason": ConsentRefusal.Reason.hostUnverified.rawValue]))
            return connection.close()
        }
        let link = channel.attach { line in connection.write(line) }
        connection.write(HelperWire.line(["ok": true]))
        var buffer = HelperWire.LineBuffer()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        reading: while true {
            let count = read(client, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            guard let lines = buffer.append(Data(bytes[0..<count])) else { break }
            for line in lines {
                guard let message = HelperWire.object(line) else { break reading }
                guard message["type"] as? String == "machine_consent", let id = message["id"] as? Int else { continue }
                let result = message["ok"] as? Bool == true ? message["result"].map { HelperWire.json($0) } : nil
                channel.receive(id: id, result: result, link: link)
            }
        }
        channel.detach(link)
        connection.close()
    }

    /// The audit token the kernel recorded for this connection's peer.
    static func auditToken(_ descriptor: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        return getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 ? token : nil
    }
}
