@testable import CmuxControlSocket
import Foundation
import Testing

@Suite("Socket startup waiter")
struct SocketStartupWaiterTests {
    @Test func reResolvesPathAfterTransientConnectionFailure() throws {
        let preferredPath = "/tmp/cmux-startup-wait-preferred.sock"
        let fallbackPath = "/tmp/cmux-startup-wait-fallback.sock"
        var attemptedPaths: [String] = []
        let waiter = SocketStartupWaiter(
            initialRetryDelay: 0.001,
            maximumRetryDelay: 0.001
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
}
