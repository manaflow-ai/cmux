import Darwin
import Foundation

/// Descriptor lifetime is owned by the session queue; shutdown cancels blocked I/O.
extension RemoteCLIRelayServer.Session {
    static func makeLocalSocketDescriptor() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.remote.relay", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed to create local relay socket",
            ])
        }
        return fd
    }

    static func roundTripUnixSocket(
        socketDescriptor fd: Int32,
        socketPath: String,
        request: Data,
        maximumResponseBytes: Int,
        shouldContinue: () -> Bool
    ) throws -> Data {
        guard shouldContinue() else {
            throw NSError(domain: "cmux.remote.relay", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "failed to read local cmux response",
            ])
        }
        var sendTimeout = timeval(
            tv_sec: localSocketRoundTripTimeoutSeconds,
            tv_usec: 0
        )
        withUnsafePointer(to: &sendTimeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        var receiveTimeout = timeval(
            tv_sec: localSocketRoundTripTimeoutSeconds(for: request),
            tv_usec: 0
        )
        withUnsafePointer(to: &receiveTimeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "cmux.remote.relay", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "local relay socket path is too long",
            ])
        }
        let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { rawBuffer in
            let destination = rawBuffer.baseAddress!.advanced(by: sunPathOffset)
            pathBytes.withUnsafeBytes { pathBuffer in
                destination.copyMemory(from: pathBuffer.baseAddress!, byteCount: pathBytes.count)
            }
        }

        let addressLength = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "cmux.remote.relay", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "failed to connect to local cmux socket",
            ])
        }
        guard shouldContinue() else {
            throw NSError(domain: "cmux.remote.relay", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "failed to read local cmux response",
            ])
        }

        try request.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var pointer = baseAddress
            while bytesRemaining > 0 {
                let written = Darwin.write(fd, pointer, bytesRemaining)
                if written <= 0 {
                    throw NSError(domain: "cmux.remote.relay", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "failed to write relay request",
                    ])
                }
                bytesRemaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        _ = shutdown(fd, SHUT_WR)

        var response = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &scratch, scratch.count)
            if count > 0 {
                guard response.count <= maximumResponseBytes - count else {
                    throw NSError(domain: "cmux.remote.relay", code: 6, userInfo: [
                        NSLocalizedDescriptionKey: "local cmux response is too large"
                    ])
                }
                response.append(scratch, count: count)
                continue
            }
            if count == 0 {
                break
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                if !response.isEmpty {
                    break
                }
                throw NSError(domain: "cmux.remote.relay", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "timed out waiting for local cmux response",
                ])
            }
            throw NSError(domain: "cmux.remote.relay", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "failed to read local cmux response",
            ])
        }
        return response
    }
}
