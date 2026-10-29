// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import CmuxNextCompat
import CmuxNextWakeups

/// This app's connection to the helper's host consent socket (`host_socket`
/// in `configure`). The helper checks this app by the connection's audit
/// token (a team-signed cmux main app) and asks its consent questions here;
/// nothing on the helper's stdin can answer one. This side checks the server
/// on the same connection: this user, the helper pid this app started, and,
/// when this app has a team, the helper's own signature (its identifier and
/// this app's team) by audit token. Then this app's first line is the
/// per-launch host secret (`host_secret` in `configure`, never on disk),
/// and the helper must answer `{"ok":true}`.
nonisolated final class ComputerUseHelperV2HostLink: Sendable {
    private let descriptor: Mutex<Int32>
    /// The helper's lines (questions and refusal records), until it closes.
    let lines: AsyncStream<Data>

    private init(descriptor: Int32, lines: AsyncStream<Data>) {
        self.descriptor = Mutex(descriptor)
        self.lines = lines
    }

    /// Connects, checks the peer and presents `secret`; nil on any failure.
    @concurrent static func connect(path: String, helperPID: pid_t, executable: URL, secret: Data,
                                    team: String? = ComputerUseHelperV2.ownTeam) async -> ComputerUseHelperV2HostLink? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: @concurrent, never on the main actor; a local Unix socket connect.
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, let peer = UnixSocketPeer(descriptor: descriptor), peer.uid == getuid(),
              peer.pid == helperPID,
              team.map({ peer.signed(team: $0, identifier: ComputerUseHelperV2.codeIdentifier(executable)) }) ?? true else {
            Darwin.close(descriptor)
            return nil
        }
        guard writeAll(descriptor, ComputerUseHelperV2.line(["secret": ComputerUseHelperV2.hex(secret)])),
              let first = firstLine(descriptor),
              (try? JSONSerialization.jsonObject(with: first) as? [String: Any])?["ok"] as? Bool == true else {
            Darwin.close(descriptor)
            return nil
        }
        // The reader thread owns a duplicate; `close()` shuts the socket down, which ends it.
        let reader = dup(descriptor)
        guard reader >= 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return ComputerUseHelperV2HostLink(descriptor: descriptor, lines: DisclaimedHelperSpawner.lines(from: reader))
    }

    /// The helper's first line, read a byte at a time (so nothing after it
    /// is consumed) within 5 s; nil on EOF, timeout or a long line.
    private static func firstLine(_ descriptor: Int32) -> Data? {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        defer {
            var none = timeval()
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &none, size)
        }
        var line = Data()
        var byte: UInt8 = 0
        while line.count < 4096 {
            // concurrency-allow: called from @concurrent connect, never on the main actor; one short bounded line.
            let count = read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return nil
    }

    /// Writes one line, off the main actor. False once closed.
    @discardableResult
    @concurrent func send(_ line: Data) async -> Bool {
        descriptor.withLock { descriptor in descriptor >= 0 && Self.writeAll(descriptor, line) }
    }

    private static func writeAll(_ descriptor: Int32, _ line: Data) -> Bool {
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return raw.isEmpty }
            var offset = 0
            while offset < raw.count {
                // concurrency-allow: called off the main actor (@concurrent); one short line to a local socket.
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written <= 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
    }

    /// Closes the link: the helper drops this app as its host.
    func close() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}
