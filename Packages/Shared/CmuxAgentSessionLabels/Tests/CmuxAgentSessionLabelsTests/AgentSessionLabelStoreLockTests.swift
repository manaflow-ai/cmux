#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing

@testable import CmuxAgentSessionLabels

/// What a writer does when the lock is held, unusable or missing its directory.
///
/// Two `cmux sessions label` processes hit these paths, so each one has to end in
/// a sentence naming the file rather than in a hang or a raw errno.
struct AgentSessionLabelStoreLockTests {
    private let now = Date(timeIntervalSince1970: 1_790_536_000)

    /// A store whose write gives up quickly, and its file and lock paths.
    private func makeStore(
        timeout: Duration = .milliseconds(80)
    ) -> (AgentSessionLabelStore, URL, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-agent-session-labels-\(UUID().uuidString)")
            .appendingPathComponent("state")
        let file = directory.appendingPathComponent(AgentSessionLabelStore.fileName)
        let store = AgentSessionLabelStore(fileURL: file, writeTimeout: timeout)
        return (store, file, URL(
            fileURLWithPath: file.path + AgentSessionLabelStoreLock.fileSuffix
        ))
    }

    private func key(_ agent: String, _ sessionID: String) throws -> AgentSessionLabelKey {
        try AgentSessionLabelKey(agent: agent, sessionID: sessionID)
    }

    /// Takes the sidecar lock the way another process would, and hands it back.
    private func holdingTheLock<T>(
        _ sidecar: URL, _ body: () async throws -> T
    ) async throws -> T {
        try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(sidecar.path, O_RDWR | O_CREAT, 0o600)
        #expect(descriptor >= 0)
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try await body()
    }

    private func message(_ body: () async throws -> some Any) async -> String {
        do {
            _ = try await body()
            return ""
        } catch let error as AgentSessionLabelError {
            return error.description
        } catch {
            return String(describing: error)
        }
    }

    @Test func aPeerHoldingTheLockFailsTheWriteWithTheFileAndTheWaitNamed() async throws {
        let (store, file, sidecar) = makeStore()
        let text = try await holdingTheLock(sidecar) {
            await message { try await store.setLabel("audit rows", for: key("codex", "s-1"), now: now) }
        }
        // A command line has to say which file is busy and how long it waited,
        // not print `EWOULDBLOCK` or wait behind a wedged peer forever.
        #expect(text == "\(file.path) could not be written: "
            + "another writer held the lock for more than 80 ms")
    }

    @Test func cancellingAWriteThatIsWaitingStopsItInsteadOfWaitingOut() async throws {
        // Long enough that finishing the wait would fail this test on time, so a
        // pass means the cancellation was what ended it.
        let (store, _, sidecar) = makeStore(timeout: .seconds(60))
        try await holdingTheLock(sidecar) {
            let started = ContinuousClock.now
            let write = Task {
                try await store.setLabel("audit rows", for: key("codex", "s-1"), now: now)
            }
            try await Task.sleep(for: .milliseconds(30))
            write.cancel()
            let result = await write.result
            #expect(throws: CancellationError.self) { try result.get() }
            #expect(started.duration(to: .now) < .seconds(5))
        }
    }

    @Test func aLockFileThatIsNotAPlainFileIsRefusedRatherThanUsed() async throws {
        let (store, file, sidecar) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        #expect(mkfifo(sidecar.path, 0o600) == 0)
        let text = await message {
            try await store.setLabel("audit rows", for: key("codex", "s-1"), now: now)
        }
        // `flock` on something that is not a plain file this user owns locks
        // nothing another writer would see, so it must not pass for a lock.
        #expect(text == "\(file.path) could not be written: "
            + "its lock file is not a plain file this user owns")
    }

    @Test func aLockFileThatIsASymlinkIsRefusedRatherThanFollowed() async throws {
        let (store, file, sidecar) = makeStore()
        let manager = FileManager.default
        try manager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try manager.createSymbolicLink(
            at: sidecar,
            withDestinationURL: file.deletingLastPathComponent()
                .appendingPathComponent("somewhere-else")
        )
        let text = await message {
            try await store.setLabel("audit rows", for: key("codex", "s-1"), now: now)
        }
        // Following it would take a lock on a file outside the state directory,
        // and create it there, which is the shape of a planted symlink.
        #expect(text.hasPrefix("\(file.path) could not be written: "
            + "its lock file could not be opened:"))
        #expect(!manager.fileExists(
            atPath: file.deletingLastPathComponent().appendingPathComponent("somewhere-else").path
        ))
    }

    @Test func aDirectoryThatCannotBeCreatedFailsTheWriteWithItsReason() async throws {
        let (store, file, _) = makeStore()
        // The state directory's own path is already a file, so creating it fails
        // before there is anything to lock.
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: parent)
        let text = await message {
            try await store.setLabel("audit rows", for: key("codex", "s-1"), now: now)
        }
        #expect(text.hasPrefix("\(file.path) could not be written: "
            + "its directory could not be created:"))
        #expect(!text.contains("UserInfo"))
    }

    @Test func manyWritesLeaveNoOpenDescriptorsBehind() async throws {
        let (store, _, sidecar) = makeStore()
        // Counting every descriptor would count the other tests in this process
        // too, so only the ones pointing at this store's own lock are counted.
        func heldLockDescriptors() -> Int? {
            let manager = FileManager.default
            guard let names = try? manager.contentsOfDirectory(atPath: "/proc/self/fd") else {
                return nil
            }
            return names.filter { name in
                (try? manager.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(name)"))
                    == sidecar.path
            }.count
        }
        // A platform whose descriptor list is not readable through the file
        // system gives no signal here; the package's own CI lane is Linux.
        guard heldLockDescriptors() != nil else { return }
        for index in 0..<50 {
            try await store.setLabel("row \(index)", for: key("codex", "s-\(index)"), now: now)
        }
        // The lock's descriptor is closed by hand on every path out of `acquire`
        // and in `release()`, so anything left here is a path that skipped it.
        #expect(heldLockDescriptors() == 0)
    }
}
