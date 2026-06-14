import Darwin

final class SSHPTYAttachReconnectInputFilterControl: Sendable {
    private let stopSignalWriteFD: Int32

    init(stopSignalWriteFD: Int32) {
        self.stopSignalWriteFD = stopSignalWriteFD
    }

    deinit {
        Darwin.close(stopSignalWriteFD)
    }

    func stopFiltering() {
        var byte: UInt8 = 1
        while true {
            let written = withUnsafePointer(to: &byte) { pointer in
                Darwin.write(stopSignalWriteFD, pointer, 1)
            }
            if written > 0 || errno != EINTR {
                return
            }
        }
    }
}
