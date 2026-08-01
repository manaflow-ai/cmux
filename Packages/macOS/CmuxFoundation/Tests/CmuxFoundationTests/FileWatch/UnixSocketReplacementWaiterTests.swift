import Darwin
import Foundation
import Testing

@testable import CmuxFoundation

private final class ReplacementOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UnixSocketReplacementWaiter.Outcome?

    var value: UnixSocketReplacementWaiter.Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ outcome: UnixSocketReplacementWaiter.Outcome) {
        lock.lock()
        stored = outcome
        lock.unlock()
    }
}

@Suite struct UnixSocketReplacementWaiterTests {
    @Test
    func deadSameInodeAndUnrelatedParentWriteWaitForExactReplacement() throws {
        // sockaddr_un caps socket paths at ~104 bytes; the user temporary
        // directory (/var/folders/.../T/) plus a full UUID overflows that, so
        // bind fails before the waiter is exercised. Keep the path short.
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-srw-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        let waiter = UnixSocketReplacementWaiter()
        let originalFD = try bindUnixSocket(at: socketPath)
        let originalIdentity = try #require(
            waiter.socketIdentity(at: socketPath)
        )
        // Closing the only descriptor leaves a bound-but-dead socket inode.
        Darwin.close(originalFD)

        let registered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let outcome = ReplacementOutcomeBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = waiter.wait(
                at: socketPath,
                replacing: originalIdentity,
                timeout: 3,
                onRegistered: { registered.signal() }
            )
            outcome.set(value)
            completed.signal()
        }
        #expect(registered.wait(timeout: .now() + 1) == .success)

        // A sibling write wakes the directory vnode but must not satisfy the
        // exact-inode predicate. The dead original inode is still present.
        try Data("unrelated".utf8).write(
            to: directory.appendingPathComponent("other.txt")
        )
        #expect(completed.wait(timeout: .now() + 0.15) == .timedOut)
        #expect(
            waiter.socketIdentity(at: socketPath)
                == originalIdentity
        )

        unlink(socketPath)
        let replacementFD = try bindUnixSocket(at: socketPath)
        defer { Darwin.close(replacementFD) }
        #expect(completed.wait(timeout: .now() + 1) == .success)
        guard case .replaced? = outcome.value else {
            return #expect(Bool(false), "exact socket replacement must wake")
        }
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "socket path exceeds sockaddr_un limit: \(path)",
                ]
            )
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let buffer = UnsafeMutableRawPointer(tuplePointer)
                    .assumingMemoryBound(to: CChar.self)
                strncpy(buffer, pointer, maxLength - 1)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = posixError("bind")
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation) failed: \(String(cString: strerror(errno)))",
            ]
        )
    }
}
