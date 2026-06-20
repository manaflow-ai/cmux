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
        if stopAcknowledgementReady() {
            waitForStopAcknowledgement()
            return
        }
        signalStopFiltering()
        waitForStopAcknowledgement()
    }

    func requestStopFiltering() {
        guard !stopAcknowledgementReady() else {
            return
        }
        signalStopFiltering()
    }

    func requestStopFiltering(unlessAlreadyRequested alreadyRequested: inout Bool) {
        guard !alreadyRequested else {
            return
        }
        requestStopFiltering()
        alreadyRequested = true
    }

    private func stopAcknowledgementReady() -> Bool {
        let events = Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        var pollFD = pollfd(fd: stopAcknowledgementReadFD, events: events, revents: 0)
        while true {
            let result = Darwin.poll(&pollFD, 1, 0)
            if result > 0 {
                return (pollFD.revents & events) != 0
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                return true
            }
        }
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
