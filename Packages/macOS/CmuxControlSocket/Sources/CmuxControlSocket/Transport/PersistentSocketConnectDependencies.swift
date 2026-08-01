internal import Darwin

struct PersistentSocketConnectDependencies: Sendable {
    let makeSocket: @Sendable () -> Int32
    let connect: @Sendable (Int32, String) -> Int32

    static let live = PersistentSocketConnectDependencies(
        makeSocket: { Darwin.socket(AF_UNIX, SOCK_STREAM, 0) },
        connect: { socket, path in
            connectUnixSocket(socket, to: path)
        }
    )
}

private func connectUnixSocket(_ socket: Int32, to path: String) -> Int32 {
    var address = sockaddr_un()
    memset(&address, 0, MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= maximumLength else {
        Darwin.__error().pointee = ENAMETOOLONG
        return -1
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        let buffer = UnsafeMutableRawPointer(pointer)
            .assumingMemoryBound(to: CChar.self)
        for index in pathBytes.indices {
            buffer[index] = pathBytes[index]
        }
    }
    let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
    let addressLength = socklen_t(pathOffset + pathBytes.count)
#if os(macOS)
    address.sun_len = UInt8(min(Int(addressLength), 255))
#endif
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(
            to: sockaddr.self,
            capacity: 1
        ) { socketAddress in
            Darwin.connect(socket, socketAddress, addressLength)
        }
    }
}
