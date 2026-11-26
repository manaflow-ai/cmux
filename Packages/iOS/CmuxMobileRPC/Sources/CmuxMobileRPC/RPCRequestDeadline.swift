import Foundation

struct RPCRequestDeadline: Sendable {
    private let deadlineNanos: UInt64

    var uptimeNanoseconds: UInt64 { deadlineNanos }

    init(timeoutNanoseconds: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(timeoutNanoseconds)
        self.deadlineNanos = overflow ? UInt64.max : deadline
    }

    func remainingNanoseconds() throws -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineNanos else {
            throw MobileShellConnectionError.requestTimedOut
        }
        return deadlineNanos - now
    }
}
