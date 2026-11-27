import Darwin
import Foundation

struct SimulatorWebInspectorSocketConnector: Sendable {
    private let frameCodec: SimulatorWebInspectorPlistFrameCodec

    init(frameCodec: SimulatorWebInspectorPlistFrameCodec = SimulatorWebInspectorPlistFrameCodec()) {
        self.frameCodec = frameCodec
    }

    func connect(path: String) throws -> SimulatorWebInspectorSocket {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < pathCapacity else {
            throw SimulatorWebInspectorError.invalidSocketPath
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SimulatorWebInspectorError.socketFailure(errno)
        }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw SimulatorWebInspectorError.socketFailure(failure)
        }
        return SimulatorWebInspectorSocket(descriptor: descriptor, frameCodec: frameCodec)
    }
}
