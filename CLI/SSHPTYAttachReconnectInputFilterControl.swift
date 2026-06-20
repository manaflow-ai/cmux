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

    @discardableResult
    func stopFiltering(timeoutMilliseconds: Int32? = nil) -> Bool {
        if stopAcknowledgementReady() {
            return waitForStopAcknowledgement(timeoutMilliseconds: timeoutMilliseconds)
        }
        signalStopFiltering()
        return waitForStopAcknowledgement(timeoutMilliseconds: timeoutMilliseconds)
    }

    func stopFilteringBeforeFirstOutput(unlessAlreadyRequested alreadyRequested: inout Bool) {
        guard !alreadyRequested else {
            return
        }
        stopFiltering(timeoutMilliseconds: 250)
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

    private func waitForStopAcknowledgement(timeoutMilliseconds: Int32?) -> Bool {
        if let timeoutMilliseconds,
           !stopAcknowledgementReady(timeoutMilliseconds: timeoutMilliseconds) {
            return false
        }
        var byte: UInt8 = 0
        while true {
            let count = withUnsafeMutablePointer(to: &byte) { pointer in
                Darwin.read(stopAcknowledgementReadFD, pointer, 1)
            }
            if count > 0 || count == 0 || errno != EINTR {
                return true
            }
        }
    }

    private func stopAcknowledgementReady(timeoutMilliseconds: Int32) -> Bool {
        let events = Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        var pollFD = pollfd(fd: stopAcknowledgementReadFD, events: events, revents: 0)
        while true {
            let result = Darwin.poll(&pollFD, 1, timeoutMilliseconds)
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
}
