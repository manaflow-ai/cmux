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
            == Data(LocalLinuxRuntime.rootfsSchemaVersion.utf8))

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

        let alternateRoot = fixture.baseURL.appendingPathComponent("alternate")
        await #expect(throws: LocalLinuxError.configurationMismatch) {
            try await runtime.bootIfNeeded(rootURL: alternateRoot)
        }
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
            openSession: { command, environment, columns, rows, output in
                openEvents.continuation.yield(OpenSessionEvent(
                    command: command,
                    environment: environment,
                    columns: columns,
                    rows: rows
                ))
                output(Data("welcome\n".utf8))
                return LocalLinuxTestKernelSession(
                    processID: 42,
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
        #expect(session.processID == 42)

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
        // Explicit close is idempotent after hangup.
        await session.close()
        #expect(await hangupIterator.next() == nil)
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

        func seedValidRootfs(marker: String = LocalLinuxRuntime.rootfsSchemaVersion) throws {
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
