import Darwin
import Foundation

/// Blocking Unix socket calls, run off the main actor.
nonisolated enum RemoteSocket {
    static func connect(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CmuxRemoteError.refused("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CmuxRemoteError.refused("socket: \(errno)") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: called from a detached task, never the main actor; a local Unix socket connect.
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw CmuxRemoteError.refused("cmux Remote is not listening")
        }
        return descriptor
    }

    static func peerPID(_ descriptor: Int32) -> Int32? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                // concurrency-allow: called from a detached task or a dedicated thread, never the main actor.
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// One line, byte by byte (the opening exchange only; the channel's later lines are read by its own reader).
    static func readLine(_ descriptor: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < 1 << 20 {
            // concurrency-allow: called from a detached task, never the main actor; the host answers at once.
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return nil
    }
}

