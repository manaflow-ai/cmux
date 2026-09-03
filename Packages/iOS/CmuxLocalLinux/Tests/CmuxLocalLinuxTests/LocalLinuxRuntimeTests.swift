import Foundation
import Testing

@testable import CmuxLocalLinux

@Suite("Local Linux runtime")
struct LocalLinuxRuntimeTests {
    @Test("boot imports a rootfs once and reuses its persisted marker")
    func bootIsIdempotentAndPersistent() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }

        let importCountURL = fixture.baseURL.appendingPathComponent("imports")
        let bootCountURL = fixture.baseURL.appendingPathComponent("boots")
        let bridge = Self.bridge(
            importCountURL: importCountURL,
            bootCountURL: bootCountURL
        )
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: fixture.archiveURL
        )

        try await runtime.bootIfNeeded()
        try await runtime.bootIfNeeded()

        // The same runtime returns its settled result without touching the
        // process-global bridge a second time.
        #expect(Self.count(at: importCountURL) == 1)
        #expect(Self.count(at: bootCountURL) == 1)
        #expect(FileManager.default.fileExists(
            atPath: fixture.rootURL.appendingPathComponent("data").path
        ))
        #expect(try Data(contentsOf: fixture.rootURL.appendingPathComponent(".rootfs-version"))
            == LocalLinuxRuntime.rootfsMarker(digest: nil))

        // A new runtime instance can boot the persisted fakefs without a
        // second archive import.
        let secondRuntime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: fixture.archiveURL
        )
        try await secondRuntime.bootIfNeeded()
        #expect(Self.count(at: importCountURL) == 1)
        #expect(Self.count(at: bootCountURL) == 2)
    }

    @Test("a changed bundled archive digest replaces the installed rootfs once")
    func changedArchiveDigestReimportsOnce() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let oldMarker = LocalLinuxRuntime.rootfsMarker(digest: "aa" + String(repeating: "0", count: 62))
        try fixture.seedValidRootfs(marker: String(decoding: oldMarker, as: UTF8.self))

        let importCountURL = fixture.baseURL.appendingPathComponent("imports")
        let bootCountURL = fixture.baseURL.appendingPathComponent("boots")
        let bridge = Self.bridge(importCountURL: importCountURL, bootCountURL: bootCountURL)
        let newDigest = "BB" + String(repeating: "1", count: 62)

        // A new bundled image with the same schema but a different digest is
        // imported over the old install, then remembered by its marker.
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: fixture.archiveURL,
            rootfsArchiveDigest: newDigest
        )
        try await runtime.bootIfNeeded()
        #expect(Self.count(at: importCountURL) == 1)
        #expect(Self.count(at: bootCountURL) == 1)
        let markerURL = fixture.rootURL.appendingPathComponent(".rootfs-version")
        #expect(try Data(contentsOf: markerURL)
            == Data("\(LocalLinuxRuntime.rootfsSchemaVersion)\n\(newDigest.lowercased())".utf8))

        // The same digest on a later launch boots the install without importing.
        let secondRuntime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: fixture.archiveURL,
            rootfsArchiveDigest: newDigest.lowercased()
        )
        try await secondRuntime.bootIfNeeded()
        #expect(Self.count(at: importCountURL) == 1)
        #expect(Self.count(at: bootCountURL) == 2)
    }

    @Test("a failed replacement restores the previous rootfs and remembers the error")
    func failedActivationRollsBackAtomically() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.seedValidRootfs(marker: "old-schema")
        let oldDataURL = fixture.rootURL
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("keep.txt")
        try Data("old-root".utf8).write(to: oldDataURL)

        let importCountURL = fixture.baseURL.appendingPathComponent("imports")
        let bootCountURL = fixture.baseURL.appendingPathComponent("boots")
        let bridge = LocalLinuxTestKernelBridge(
            importRootfs: { _, destinationPath in
                Self.increment(at: importCountURL)
                let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: destination.appendingPathComponent("data", isDirectory: true),
                    withIntermediateDirectories: true
                )
                try Data("new-root".utf8).write(
                    to: destination.appendingPathComponent("data/replace.txt")
                )
            },
            boot: { _, _ in
                Self.increment(at: bootCountURL)
                throw LocalLinuxKernelBridgeError.bootFailed(errno: -5)
            }
        )
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: fixture.archiveURL
        )

        await #expect(throws: LocalLinuxError.bootFailed(errno: -5)) {
            try await runtime.bootIfNeeded()
        }
        // The old directory and marker survive the failed activation.
        #expect(try Data(contentsOf: oldDataURL) == Data("old-root".utf8))
        #expect(try Data(contentsOf: fixture.rootURL.appendingPathComponent(".rootfs-version"))
            == Data("old-schema".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.rootURL
                .appendingPathComponent("data/replace.txt")
                .path
        ))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.baseURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".import-")
                || $0.lastPathComponent.hasPrefix(".rootfs-backup-")
        }
        #expect(leftovers.isEmpty)

        // The first failure is retained, so a retry does not import or boot
        // against another partially initialized root.
        await #expect(throws: LocalLinuxError.bootFailed(errno: -5)) {
            try await runtime.bootIfNeeded()
        }
        #expect(Self.count(at: importCountURL) == 1)
        #expect(Self.count(at: bootCountURL) == 1)
    }

    @Test("an injected kernel session forwards output, input, resize, and hangup")
    func injectedSessionLifecycleIsObservable() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.seedValidRootfs()

        let openEvents = AsyncStream<OpenSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        let inputEvents = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let resizeEvents = AsyncStream<ResizeEvent>.makeStream(bufferingPolicy: .unbounded)
        let hangupEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)

        let bridge = LocalLinuxTestKernelBridge(
            boot: { _, _ in },
            openSession: { command, environment, columns, rows, output, _, _ in
                openEvents.continuation.yield(OpenSessionEvent(
                    command: command,
                    environment: environment,
                    columns: columns,
                    rows: rows
                ))
                output(Data("welcome\n".utf8))
                return LocalLinuxTestKernelSession(
                    send: { data in
                        inputEvents.continuation.yield(data)
                        return data.count
                    },
                    resize: { columns, rows in
                        resizeEvents.continuation.yield(ResizeEvent(columns: columns, rows: rows))
                    },
                    hangup: {
                        hangupEvents.continuation.yield(())
                        hangupEvents.continuation.finish()
                    }
                )
            }
        )
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: nil
        )
        try await runtime.bootIfNeeded()

        let session = try await runtime.openSession(
            command: ["/bin/sh", "-i"],
            environment: ["TERM=xterm-256color"],
            columns: 80,
            rows: 24
        )
        var openIterator = openEvents.stream.makeAsyncIterator()
        #expect(await openIterator.next() == OpenSessionEvent(
            command: ["/bin/sh", "-i"],
            environment: ["TERM=xterm-256color"],
            columns: 80,
            rows: 24
        ))

        var outputIterator = session.output.makeAsyncIterator()
        #expect(await outputIterator.next() == Data("welcome\n".utf8))

        let input = Data("echo ok\n".utf8)
        #expect(try await session.send(input) == input.count)
        var inputIterator = inputEvents.stream.makeAsyncIterator()
        #expect(await inputIterator.next() == input)

        try await session.resize(columns: 100, rows: 40)
        var resizeIterator = resizeEvents.stream.makeAsyncIterator()
        #expect(await resizeIterator.next() == ResizeEvent(columns: 100, rows: 40))

        await session.hangup()
        var hangupIterator = hangupEvents.stream.makeAsyncIterator()
        #expect(await hangupIterator.next() != nil)
        #expect(await outputIterator.next() == nil)
        await #expect(throws: LocalLinuxError.closed) {
            try await session.send(Data("after-close".utf8))
        }
        // A repeated hangup is idempotent.
        await session.hangup()
        #expect(await hangupIterator.next() == nil)
    }

    @Test("beginClose is an idempotent asynchronous hangup fence")
    func beginCloseIsIdempotent() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.seedValidRootfs()

        let hangupCount = LocalLinuxHangupCounter()
        let bridge = LocalLinuxTestKernelBridge(
            boot: { _, _ in },
            openSession: { _, _, _, _, _, _, _ in
                LocalLinuxTestKernelSession(
                    hangup: {
                        hangupCount.increment()
                    }
                )
            }
        )
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: nil
        )
        try await runtime.bootIfNeeded()

        let session = try await runtime.openSession(
            command: ["/bin/sh"],
            environment: [],
            columns: 80,
            rows: 24
        )

        // A synchronous owner can claim a fence without blocking. An actor
        // close racing that claim must await the same one-shot kernel call.
        let fence = session.beginClose()
        let concurrentClose = Task {
            await session.hangup()
        }
        await fence.value
        await concurrentClose.value
        #expect(await session.isEnded)
        #expect(hangupCount.value == 1)

        // Repeated closes remain harmless after the fence has completed.
        let repeatedFence = session.beginClose()
        await repeatedFence.value
        await session.hangup()
        #expect(hangupCount.value == 1)
    }

    @Test("natural kernel termination finishes output and closes the session")
    func naturalTerminationFinishesSession() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.seedValidRootfs()

        let bridge = LocalLinuxTestKernelBridge(
            boot: { _, _ in },
            openSession: { _, _, _, _, output, onTermination, _ in
                output(Data("done\n".utf8))
                // The bridge contract is one-shot. Calling the callback twice
                // must finish the stream once, and bytes after termination
                // must not leak to consumers.
                onTermination()
                onTermination()
                output(Data("late\n".utf8))
                return LocalLinuxTestKernelSession()
            }
        )
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: nil
        )
        try await runtime.bootIfNeeded()

        let session = try await runtime.openSession(
            command: ["/bin/sh"],
            environment: [],
            columns: 80,
            rows: 24
        )
        var outputIterator = session.output.makeAsyncIterator()
        #expect(await outputIterator.next() == Data("done\n".utf8))
        #expect(await outputIterator.next() == nil)
        await #expect(throws: LocalLinuxError.closed) {
            try await session.send(Data("after-exit".utf8))
        }
    }

    @Test("input readiness callback wakes a blocked writer and finishes on hangup")
    func inputReadinessIsCoalescedAndFinished() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.seedValidRootfs()

        let bridge = LocalLinuxTestKernelBridge(
            boot: { _, _ in },
            openSession: { _, _, _, _, _, _, onInputReady in
                // Emit before the runtime returns so the stream's one-element
                // buffer covers the write-to-waiter hand-off race.
                onInputReady()
                onInputReady()
                return LocalLinuxTestKernelSession()
            }
        )
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: nil
        )
        try await runtime.bootIfNeeded()

        let session = try await runtime.openSession(
            command: ["/bin/sh"],
            environment: [],
            columns: 80,
            rows: 24
        )
        var iterator = session.inputReady.makeAsyncIterator()

        #expect(await iterator.next() != nil)

        await session.hangup()
        #expect(await iterator.next() == nil)
    }

    @Test("output overflow bounds chunks and hangs up the kernel")
    func outputOverflowFinishesAndRequestsHangup() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.seedValidRootfs()

        let chunkByteLimit = 64 * 1024
        let bufferedChunkCapacity = 64
        let hangupCount = LocalLinuxHangupCounter()
        let hangupEvents = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let bridge = LocalLinuxTestKernelBridge(
            boot: { _, _ in },
            openSession: { _, _, _, _, output, _, _ in
                // Do not create a consumer until openSession returns. This
                // fills the bounded ingress before any output is drained.
                let payload = Data(
                    repeating: 0x61,
                    count: chunkByteLimit * (bufferedChunkCapacity + 1)
                )
                output(payload)
                // The overflow transition must stop later callback bytes.
                output(Data("post-overflow\n".utf8))
                return LocalLinuxTestKernelSession(
                    hangup: {
                        hangupCount.increment()
                        hangupEvents.continuation.yield(())
                    }
                )
            }
        )
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: nil
        )
        try await runtime.bootIfNeeded()

        // The bridge emitted the whole payload synchronously before this call
        // returned, so all stream values below were queued before draining.
        let session = try await runtime.openSession(
            command: ["/bin/sh"],
            environment: [],
            columns: 80,
            rows: 24
        )
        #expect(await session.isEnded)
        // Overflow requests teardown while the bridge is still opening. The
        // hangup must be observed before this test starts draining the stream.
        // Await the event instead of polling scheduler turns, because the C
        // hangup runs on a detached worker by design.
        var hangupIterator = hangupEvents.stream.makeAsyncIterator()
        #expect(await hangupIterator.next() != nil)
        #expect(hangupCount.value == 1)

        var iterator = session.output.makeAsyncIterator()
        var chunks: [Data] = []
        while let chunk = await iterator.next() {
            chunks.append(chunk)
        }

        #expect(chunks.count == bufferedChunkCapacity)
        #expect(chunks.allSatisfy { $0.count <= chunkByteLimit })
        #expect(chunks.allSatisfy { $0.allSatisfy { $0 == 0x61 } })
        #expect(chunks.reduce(0) { $0 + $1.count } == chunkByteLimit * bufferedChunkCapacity)
        // An explicit hangup after the overflow teardown is a no-op.
        await session.hangup()
        #expect(hangupCount.value == 1)
    }

    @Test("missing archive fails before invoking the injected bridge")
    func missingArchiveFailsClosed() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let bridge = LocalLinuxTestKernelBridge()
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: fixture.rootURL,
            rootfsArchiveURL: nil
        )

        await #expect(throws: LocalLinuxError.rootfsAssetMissing) {
            try await runtime.bootIfNeeded()
        }
    }

    private static func bridge(
        importCountURL: URL,
        bootCountURL: URL
    ) -> LocalLinuxTestKernelBridge {
        LocalLinuxTestKernelBridge(
            importRootfs: { _, destinationPath in
                increment(at: importCountURL)
                let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: destination.appendingPathComponent("data", isDirectory: true),
                    withIntermediateDirectories: true
                )
                // fakefs_import also emits a sibling database. Keeping it in
                // the fixture makes the whole-root move observable.
                try Data("meta".utf8).write(
                    to: destination.appendingPathComponent("meta.db")
                )
            },
            boot: { _, _ in
                increment(at: bootCountURL)
            }
        )
    }

    private static func increment(at url: URL) {
        let current = count(at: url)
        try? Data(String(current + 1).utf8).write(to: url, options: .atomic)
    }

    private static func count(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let value = Int(String(decoding: data, as: UTF8.self)) else {
            return 0
        }
        return value
    }

    private struct RuntimeFixture {
        let baseURL: URL
        let rootURL: URL
        let archiveURL: URL

        init() throws {
            let baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("CmuxLocalLinuxRuntimeTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: baseURL,
                withIntermediateDirectories: true
            )
            self.baseURL = baseURL
            self.rootURL = baseURL.appendingPathComponent("root", isDirectory: true)
            self.archiveURL = baseURL.appendingPathComponent("alpine.tar.gz")
            try Data("test archive".utf8).write(to: archiveURL)
        }

        func seedValidRootfs(
            marker: String = String(decoding: LocalLinuxRuntime.rootfsMarker(digest: nil), as: UTF8.self)
        ) throws {
            let dataURL = rootURL.appendingPathComponent("data", isDirectory: true)
            try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
            try Data("meta".utf8).write(to: rootURL.appendingPathComponent("meta.db"))
            try Data(marker.utf8).write(to: rootURL.appendingPathComponent(".rootfs-version"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    private struct OpenSessionEvent: Equatable, Sendable {
        let command: [String]
        let environment: [String]
        let columns: Int32
        let rows: Int32
    }

    private struct ResizeEvent: Equatable, Sendable {
        let columns: Int32
        let rows: Int32
    }
}

private final class LocalLinuxHangupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let stream = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        events = stream.stream
        continuation = stream.continuation
    }

    func increment() {
        lock.withLock {
            count += 1
        }
        continuation.yield(())
    }

    var value: Int {
        lock.withLock { count }
    }
}
