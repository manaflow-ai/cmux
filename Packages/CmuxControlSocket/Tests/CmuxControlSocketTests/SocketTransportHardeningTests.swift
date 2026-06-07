import Darwin
import Foundation
import Testing

@testable import CmuxControlSocket

@Suite struct SocketTransportHardeningTests {
    let transport = SocketTransport()

    @Test func socketTimeoutMicrosecondsNeverReachOneMillion() {
        // 0.9999996s rounds to 1_000_000µs, which is not a valid tv_usec.
        let nearOneSecond = transport.makeSocketTimeout(0.999_999_6)
        #expect(nearOneSecond.tv_sec == 0)
        #expect(nearOneSecond.tv_usec == 999_999)

        let exact = transport.makeSocketTimeout(2.5)
        #expect(exact.tv_sec == 2)
        #expect(exact.tv_usec == 500_000)

        let negative = transport.makeSocketTimeout(-1)
        #expect(negative.tv_sec == 0)
        #expect(negative.tv_usec == 0)
    }

    @Test func acquiredLockDescriptorIsCloseOnExec() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        defer {
            unlink(path)
            unlink(path + ".lock")
        }

        guard case .acquired(let fd, _) = transport.acquireSocketPathLock(for: path) else {
            Issue.record("expected lock acquisition to succeed")
            return
        }
        defer { transport.releaseSocketPathLock(fd) }

        let flags = fcntl(fd, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0, "lock fd must not leak across fork/exec")
    }
}
