import Darwin
import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Simulator cross-process mutation gate")
struct SimulatorMutationGateTests {
    @Test("Durable ownership rejects an older process token")
    func durableOwnershipIsLastWriterWins() throws {
        let directory = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstProcess = SimulatorCrossProcessOwnershipStore(directory: directory)
        let secondProcess = SimulatorCrossProcessOwnershipStore(directory: directory)
        let components = ["DEVICE", "com.example.app"]

        let first = try firstProcess.claim(namespace: "camera", components: components)
        #expect(secondProcess.isCurrent(first, namespace: "camera", components: components))
        let second = try secondProcess.claim(namespace: "camera", components: components)

        #expect(!firstProcess.isCurrent(first, namespace: "camera", components: components))
        #expect(firstProcess.isCurrent(second, namespace: "camera", components: components))
    }

    @Test("A claim fails when ownership cannot be published")
    func failedOwnershipPublicationThrows() throws {
        let blockingFile = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        try Data().write(to: blockingFile)
        let store = SimulatorCrossProcessOwnershipStore(
            directory: blockingFile.appendingPathComponent("ownership", isDirectory: true)
        )

        #expect(throws: CocoaError.self) {
            _ = try store.claim(namespace: "camera", components: ["DEVICE", "com.example.app"])
        }
    }

    @Test("Lock descriptors cannot leak through exec")
    func descriptorIsCloseOnExec() throws {
        let directory = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = SimulatorPOSIXMutationLockFileSystem()
        try fileSystem.prepareLockDirectory(directory)
        let descriptor = try fileSystem.openLockFile(
            directory.appendingPathComponent("descriptor.lock")
        )
        defer { fileSystem.close(descriptor) }

        let flags = fcntl(descriptor, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC == FD_CLOEXEC)
    }

    @Test("Camera commits serialize against app lifecycle and privacy mutations")
    func cameraKeysSerializeAppAndPrivacy() async throws {
        let directory = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let releaseCamera = TestMutationLatch()
        let cameraEntered = TestMutationLatch()
        let fileSystem = TestMutationLockFileSystem()
        let entries = TestMutationEntryRecorder()
        let cameraGate = SimulatorMutationGate(
            lockDirectory: directory,
            fileSystem: fileSystem
        )
        let competingGate = SimulatorMutationGate(
            lockDirectory: directory,
            fileSystem: fileSystem
        )
        let appKey = SimulatorMutationKey.application(
            deviceIdentifier: "DEVICE",
            bundleIdentifier: "com.example.camera"
        )
        let tccKey = SimulatorMutationKey.tcc(deviceIdentifier: "DEVICE")

        let camera = Task {
            try await cameraGate.withLocks([tccKey, appKey]) {
                await entries.append("camera")
                await cameraEntered.open()
                await releaseCamera.wait()
            }
        }
        await cameraEntered.wait()
        await fileSystem.waitUntilAttemptCount(1)
        let lifecycle = Task {
            try await competingGate.withLocks([appKey]) {
                await entries.append("lifecycle")
            }
        }
        let privacy = Task {
            try await competingGate.withLocks([tccKey]) {
                await entries.append("privacy")
            }
        }

        await fileSystem.waitUntilAttemptCount(3)
        #expect(await entries.values == ["camera"])
        await releaseCamera.open()
        try await camera.value
        try await lifecycle.value
        try await privacy.value
        #expect(Set(await entries.values) == ["camera", "lifecycle", "privacy"])
    }

    @Test("Unrelated app keys can mutate concurrently")
    func differentKeysProceed() async throws {
        let directory = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = TestMutationLatch()
        let entries = TestMutationEntryRecorder()
        let gate = SimulatorMutationGate(lockDirectory: directory)

        let first = Task {
            try await gate.withLocks([.application(
                deviceIdentifier: "DEVICE-A",
                bundleIdentifier: "com.example.app"
            )]) {
                await entries.append("first")
                await release.wait()
            }
        }
        let second = Task {
            try await gate.withLocks([.application(
                deviceIdentifier: "DEVICE-B",
                bundleIdentifier: "com.example.app"
            )]) {
                await entries.append("second")
                await release.wait()
            }
        }

        await entries.waitUntilCount(2)
        #expect(Set(await entries.values) == ["first", "second"])
        await release.open()
        try await first.value
        try await second.value
    }

    @Test("Independent owners serialize the same BulletinBoard store")
    func bulletinBoardOwnersSerialize() async throws {
        let directory = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let releaseFirst = TestMutationLatch()
        let firstEntered = TestMutationLatch()
        let fileSystem = TestMutationLockFileSystem()
        let entries = TestMutationEntryRecorder()
        let firstOwner = SimulatorMutationGate(
            lockDirectory: directory,
            fileSystem: fileSystem
        )
        let secondOwner = SimulatorMutationGate(
            lockDirectory: directory,
            fileSystem: fileSystem
        )
        let key = SimulatorMutationKey.store(
            deviceIdentifier: "DEVICE",
            name: "BulletinBoard"
        )

        let first = Task {
            try await firstOwner.withLocks([key]) {
                await entries.append("first")
                await firstEntered.open()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()
        let second = Task {
            try await secondOwner.withLocks([key]) {
                await entries.append("second")
            }
        }

        await fileSystem.waitUntilAttemptCount(2)
        #expect(await entries.values == ["first"])
        await releaseFirst.open()
        try await first.value
        try await second.value
        #expect(await entries.values == ["first", "second"])
    }

    @Test("Cancellation closes a waiting descriptor and leaves the key reusable")
    func cancellationCleanup() async throws {
        let directory = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let releaseFirst = TestMutationLatch()
        let firstEntered = TestMutationLatch()
        let fileSystem = TestMutationLockFileSystem()
        let firstOwner = SimulatorMutationGate(
            lockDirectory: directory,
            fileSystem: fileSystem
        )
        let waitingOwner = SimulatorMutationGate(
            lockDirectory: directory,
            fileSystem: fileSystem
        )
        let key = SimulatorMutationKey.tcc(deviceIdentifier: "DEVICE")

        let first = Task {
            try await firstOwner.withLocks([key]) {
                await firstEntered.open()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()
        let cancelled = Task {
            try await waitingOwner.withLocks([key]) {}
        }
        await fileSystem.waitUntilAttemptCount(2)
        cancelled.cancel()
        await releaseFirst.open()
        try await first.value
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        try await SimulatorMutationGate(
            lockDirectory: directory,
            fileSystem: fileSystem
        ).withLocks([key]) {}
    }

    @Test("Cancellation completes while another owner still holds the lock")
    func cancellationDoesNotWaitForCurrentOwner() async throws {
        let directory = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let releaseFirst = TestMutationLatch()
        let firstEntered = TestMutationLatch()
        let fileSystem = TestMutationLockFileSystem()
        let firstOwner = SimulatorMutationGate(
            lockDirectory: directory,
            fileSystem: fileSystem
        )
        let waitingOwner = SimulatorMutationGate(
            lockDirectory: directory,
            fileSystem: fileSystem
        )
        let key = SimulatorMutationKey.tcc(deviceIdentifier: "DEVICE")

        let first = Task {
            try await firstOwner.withLocks([key]) {
                await firstEntered.open()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()
        let cancelled = Task {
            try await waitingOwner.withLocks([key]) {}
        }
        await fileSystem.waitUntilAttemptCount(2)
        cancelled.cancel()

        let cancelledBeforeDeadline = await withTaskGroup(
            of: Bool.self,
            returning: Bool.self
        ) { group in
            group.addTask {
                _ = try? await cancelled.value
                return true
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: .milliseconds(250))
                return false
            }
            let firstResult = await group.next() ?? false
            if !firstResult {
                await releaseFirst.open()
            }
            group.cancelAll()
            while await group.next() != nil {}
            return firstResult
        }

        if cancelledBeforeDeadline {
            await releaseFirst.open()
        }
        try await first.value
        #expect(cancelledBeforeDeadline)
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
    }

    private func temporaryLockDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mutation-gate-test-\(UUID().uuidString)")
    }
}
