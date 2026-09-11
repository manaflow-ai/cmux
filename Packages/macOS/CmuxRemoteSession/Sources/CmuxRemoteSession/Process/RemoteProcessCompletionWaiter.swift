internal import Darwin
internal import Foundation

struct RemoteProcessCompletionWaiter: Sendable {
    let processExitFileDescriptor: Int32
    let stdinFailureFileDescriptor: Int32

    func wait(
        until deadline: DispatchTime
    ) -> RemoteProcessCompletionWaitOutcome {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else {
                return .timedOut
            }
            let remainingNanoseconds = deadline.uptimeNanoseconds - now
            let wholeMilliseconds = remainingNanoseconds / 1_000_000
            let roundedMilliseconds = wholeMilliseconds
                + (remainingNanoseconds % 1_000_000 == 0 ? 0 : 1)
            let timeoutMilliseconds = Int32(
                min(roundedMilliseconds, UInt64(Int32.max))
            )
            var descriptors = [
                pollfd(
                    fd: processExitFileDescriptor,
                    events: Int16(POLLIN | POLLERR | POLLHUP),
                    revents: 0
                ),
                pollfd(
                    fd: stdinFailureFileDescriptor,
                    events: Int16(POLLIN | POLLERR | POLLHUP),
                    revents: 0
                ),
            ]
            let result = Darwin.poll(
                &descriptors,
                nfds_t(descriptors.count),
                timeoutMilliseconds
            )
            if result > 0 {
                if descriptors[1].revents != 0 {
                    return .stdinWriteFailed
                }
                if descriptors[0].revents != 0 {
                    return .processExited
                }
                continue
            }
            if result == 0 {
                return .timedOut
            }
            if errno != EINTR {
                return .waitFailed(errno)
            }
        }
    }
}
