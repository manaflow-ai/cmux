import Darwin

final class SSHPTYAttachReconnectInputFilterControl: Sendable {
    private let stopSignalWriteFD: Int32
    private let stopAcknowledgementReadFD: Int32

    init(stopSignalWriteFD: Int32, stopAcknowledgementReadFD: Int32) {
        self.stopSignalWriteFD = stopSignalWriteFD
        self.stopAcknowledgementReadFD = stopAcknowledgementReadFD
    }

    deinit {
        Darwin.close(stopSignalWriteFD)
        Darwin.close(stopAcknowledgementReadFD)
    }

    func stopFiltering() {
        signalStopFiltering()
        waitForStopAcknowledgement()
    }

    private func signalStopFiltering() {
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

    private func waitForStopAcknowledgement() {
        var byte: UInt8 = 0
        while true {
            let count = withUnsafeMutablePointer(to: &byte) { pointer in
                Darwin.read(stopAcknowledgementReadFD, pointer, 1)
            }
            if count > 0 || count == 0 || errno != EINTR {
                return
            }
        }
    }
}
