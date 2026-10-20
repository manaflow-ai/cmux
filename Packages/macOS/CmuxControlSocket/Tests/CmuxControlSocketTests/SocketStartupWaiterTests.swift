@testable import CmuxControlSocket
import Darwin
import Foundation
import Testing

@Suite("Socket startup waiter")
struct SocketStartupWaiterTests {
    @Test func reResolvesPathAfterTransientConnectionFailure() throws {
        let preferredPath = "/tmp/cmux-startup-wait-preferred.sock"
        let fallbackPath = "/tmp/cmux-startup-wait-fallback.sock"
        var attemptedPaths: [String] = []
        var currentTime: TimeInterval = 0
        let waiter = SocketStartupWaiter(
            initialRetryDelay: 0.001,
            maximumRetryDelay: 0.001,
            monotonicTime: {
                defer { currentTime += 0.001 }
                return currentTime
            }
        )

        let connectedPath: String = try waiter.wait(
            timeout: 1,
            resolvePath: {
                attemptedPaths.isEmpty ? preferredPath : fallbackPath
            },
            attemptConnection: { path, _ in
                attemptedPaths.append(path)
                return path == fallbackPath ? path : nil
            }
        )

        #expect(connectedPath == fallbackPath)
        #expect(attemptedPaths == [preferredPath, fallbackPath])
    }

    @Test func enforcesOneMonotonicDeadlineAcrossConnectionAttempts() {
        let socketPath = "/tmp/cmux-startup-wait-timeout.sock"
        var currentTime: TimeInterval = 0
        var observedRemainingTime: TimeInterval?
        var attemptCount = 0
        let waiter = SocketStartupWaiter(
            initialRetryDelay: 0.001,
            maximumRetryDelay: 0.001,
            monotonicTime: {
                defer { currentTime += 0.25 }
                return currentTime
            }
        )

        do {
            let _: String = try waiter.wait(
                timeout: 0.5,
                resolvePath: { socketPath },
                attemptConnection: { _, remainingTime in
                    attemptCount += 1
                    observedRemainingTime = remainingTime
                    return nil
                }
            )
            Issue.record("Expected the bounded startup wait to time out")
        } catch let timeout as SocketStartupWaitTimeout {
            #expect(timeout.path == socketPath)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(attemptCount == 1)
        #expect(observedRemainingTime == 0.25)
    }

    @Test func retriesWhenEventQueueIsUnavailable() throws {
        let socketPath = "/tmp/cmux-startup-wait-no-kqueue.sock"
        var currentTime: TimeInterval = 0
        var attemptCount = 0
        let waiter = SocketStartupWaiter(
            initialRetryDelay: 0.001,
            maximumRetryDelay: 0.001,
            monotonicTime: {
                defer { currentTime += 0.001 }
                return currentTime
            },
            eventQueueFactory: { -1 }
        )

        let connection: String = try waiter.wait(
            timeout: 1,
            resolvePath: { socketPath },
            attemptConnection: { path, _ in
                attemptCount += 1
                return attemptCount == 2 ? path : nil
            }
        )

        #expect(connection == socketPath)
        #expect(attemptCount == 2)
    }

    @Test func coalescesUnrelatedDirectoryEventStorms() throws {
        let socketPath = "/tmp/cmux-startup-wait-event-storm.sock"
        var currentTime: TimeInterval = 0
        var attemptTimes: [TimeInterval] = []
        let waiter = SocketStartupWaiter(
            initialRetryDelay: 0.01,
            maximumRetryDelay: 0.08,
            monotonicTime: { currentTime },
            eventQueueFactory: { kqueue() },
            vnodeEventWaiter: { _, remaining in
                currentTime += min(0.001, remaining)
                return true
            },
            retryDelayWaiter: { delay in
                currentTime += delay
            }
        )

        let connection: String = try waiter.wait(
            timeout: 1,
            resolvePath: { socketPath },
            attemptConnection: { path, _ in
                attemptTimes.append(currentTime)
                return attemptTimes.count == 5 ? path : nil
            }
        )

        #expect(connection == socketPath)
        let expectedAttemptTimes: [TimeInterval] = [0, 0.01, 0.02, 0.04, 0.08]
        #expect(attemptTimes.count == expectedAttemptTimes.count)
        #expect(zip(attemptTimes, expectedAttemptTimes).allSatisfy {
            abs($0 - $1) < 0.000_001
        })
    }

    @Test func propagatesPermanentFailureWithoutRetrying() {
        let socketPath = "/tmp/cmux-startup-wait-permanent-failure.sock"
        var attemptCount = 0
        let waiter = SocketStartupWaiter()

        do {
            let _: String = try waiter.wait(
                timeout: 1,
                resolvePath: { socketPath },
                attemptConnection: { _, _ in
                    attemptCount += 1
                    throw CancellationError()
                }
            )
            Issue.record("Expected the permanent connection failure to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(attemptCount == 1)
    }
}
