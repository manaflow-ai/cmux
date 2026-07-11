import Darwin
import Foundation

struct UnixSocketServer {
    let descriptor: Int32
    let path: String

    init(path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeFailure.systemCall("socket", errno) }
        self.descriptor = descriptor
        self.path = path
        unlink(path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            Darwin.close(descriptor)
            throw BridgeFailure.invalidSocketPath
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = memcpy($0, source, pathBytes.count)
                }
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length)
            }
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw BridgeFailure.systemCall("bind", errno)
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            throw BridgeFailure.systemCall("chmod", errno)
        }
        guard listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw BridgeFailure.systemCall("listen", errno)
        }
    }

    func acceptConnection() async throws -> FileHandle {
        try await Task.detached {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { throw BridgeFailure.systemCall("accept", errno) }
            return FileHandle(fileDescriptor: client, closeOnDealloc: true)
        }.value
    }

    func close() {
        Darwin.close(descriptor)
        unlink(path)
    }
}
