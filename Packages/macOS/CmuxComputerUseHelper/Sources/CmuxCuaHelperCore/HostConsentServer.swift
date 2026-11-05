// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import os

private let hostLogger = Logger(subsystem: "com.cmuxterm.cua", category: "host")

/// The cmux app's consent connection: a Unix socket the helper listens on
/// (path from `configure`, beside the helper socket). The app connects
/// after `ready`. Each connection is checked before the helper reads a byte:
/// the peer runs as this user (getpeereid), and its audit token
/// (LOCAL_PEERTOKEN, taken for this connection) passes `check`. Then its
/// first line must be `{"secret":HEX}`, this launch's host secret: the app
/// sent it only on the helper's stdin and never writes it to disk, so
/// another signed cmux install of this user cannot present it. A refused
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
    /// From `configure`; the server exists only after it, so no connection
    /// is ever served without a secret to compare.
    private let secret: Data
    private let listener = OSAllocatedUnfairLock<Int32>(initialState: -1)

    public init(path: String, secret: Data, channel: HostConsentChannel,
                check: any HostCodeChecking = CmuxAppCodeCheck()) {
        self.path = path
        self.secret = secret
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
        let refuse = { (reason: String) in
            hostLogger.error("refused host peer; consent stays off: \(reason, privacy: .public)")
            connection.write(HelperWire.line(["ok": false, "error": "refused",
                                              "reason": ConsentRefusal.Reason.hostUnverified.rawValue]))
            connection.close()
        }
        let verdict: HostVerification = if let uid = HelperSocketServer.peerUID(client), uid == geteuid() {
            Self.auditToken(client).map { check.check($0) } ?? .unverified("the peer's audit token is unreadable")
        } else {
            .unverified("the peer runs as another user")
        }
        if case .unverified(let reason) = verdict { return refuse(reason) }
        var buffer = HelperWire.LineBuffer()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var lines: [Data] = []
        while lines.isEmpty {
            let count = read(client, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0, let more = buffer.append(Data(bytes[0..<count])) else {
                return refuse("the peer did not present this launch's host secret")
            }
            lines = more
        }
        let presented = (HelperWire.object(lines.removeFirst())?["secret"] as? String).flatMap(HelperWire.unhex)
        guard let presented, !secret.isEmpty, AdmissionPolicy.constantTimeEqual(presented, secret) else {
            return refuse("the peer did not present this launch's host secret")
        }
        let link = channel.attach { line in connection.write(line) }
        connection.write(HelperWire.line(["ok": true]))
        reading: while true {
            for line in lines {
                guard let message = HelperWire.object(line) else { break reading }
                guard message["type"] as? String == "machine_consent", let id = message["id"] as? Int else { continue }
                let result = message["ok"] as? Bool == true ? message["result"].map { HelperWire.json($0) } : nil
                channel.receive(id: id, result: result, link: link)
            }
            lines = []
            let count = read(client, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0, let more = buffer.append(Data(bytes[0..<count])) else { break }
            lines = more
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
