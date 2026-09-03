import Foundation
import Testing

@testable import CmuxLocalLinux

@Suite("Local Linux computer controller")
@MainActor
struct LocalLinuxComputerControllerTests {
    @Test("concurrent starts share one pty and attachments replay its output")
    func concurrentStartsShareOneSession() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }

        let first = Task { await fixture.controller.startIfNeeded(columns: 80, rows: 24) }
        let second = Task { await fixture.controller.startIfNeeded(columns: 100, rows: 30) }
        #expect(await first.value)
        #expect(await second.value)
        #expect(fixture.controller.state == .running)
        #expect(fixture.kernel.openCount == 1)

        let attachment = try #require(await fixture.controller.attach(columns: 100, rows: 30))
        let replay = try #require(try await attachment.lane.receiveOutput())
        #expect(replay.kind == .replay)
        #expect(replay.bytes == Data("ready\n".utf8))
        await attachment.lane.close()
    }

    @Test("typeahead before the pty exists is flushed once the shell starts")
    func preStartInputIsFlushed() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }

        fixture.controller.send(Data("ls\n".utf8))
        #expect(await fixture.controller.startIfNeeded())

        var inputs = fixture.kernel.inputs.makeAsyncIterator()
        #expect(await inputs.next() == Data("ls\n".utf8))
    }

    @Test("input from a fenced generation is rejected after a retry")
    func staleGenerationInputIsRejected() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }

        let stale = try #require(await fixture.controller.attach(columns: 80, rows: 24))
        await stale.lane.close()
        fixture.controller.terminate()
        #expect(fixture.controller.state == .ended)
        #expect(fixture.controller.canRetry)

        fixture.controller.prepareForRetry()
        #expect(fixture.controller.state == .idle)
        let fresh = try #require(await fixture.controller.attach(columns: 80, rows: 24))
        #expect(fresh.generation != stale.generation)
        #expect(fixture.kernel.openCount == 2)

        fixture.controller.send(Data("old\n".utf8), generation: stale.generation)
        fixture.controller.send(Data("new\n".utf8), generation: fresh.generation)

        var inputs = fixture.kernel.inputs.makeAsyncIterator()
        #expect(await inputs.next() == Data("new\n".utf8))
        await fresh.lane.close()
    }

    @Test("lane input reaches the same queue as delegate input")
    func laneInputSharesTheControllerQueue() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }

        let attachment = try #require(await fixture.controller.attach(columns: 80, rows: 24))
        try await attachment.lane.sendInput("pwd\n")

        var inputs = fixture.kernel.inputs.makeAsyncIterator()
        #expect(await inputs.next() == Data("pwd\n".utf8))
        await attachment.lane.close()
    }

    @Test("a shell that exits before the open returns is ended, not running")
    func immediateExitIsEnded() async throws {
        let fixture = try ControllerFixture(exitsImmediately: true)
        defer { fixture.remove() }

        #expect(await fixture.controller.startIfNeeded() == false)
        #expect(fixture.controller.state == .ended)
        #expect(fixture.controller.canRetry)
        #expect(fixture.controller.lastError == nil)

        // Retry opens a fresh pty rather than reusing the dead handle.
        fixture.controller.prepareForRetry()
        #expect(await fixture.controller.startIfNeeded() == false)
        #expect(fixture.kernel.openCount == 2)
    }

    @Test("terminate hangs up the pty exactly once and drops queued input")
    func terminateHangsUpOnce() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }

        #expect(await fixture.controller.startIfNeeded())
        fixture.controller.terminate()
        fixture.controller.terminate()

        var hangups = fixture.kernel.hangups.makeAsyncIterator()
        #expect(await hangups.next() != nil)
        #expect(fixture.controller.state == .ended)
        fixture.controller.send(Data("dropped\n".utf8))
        #expect(await fixture.controller.startIfNeeded())
        #expect(fixture.kernel.hangupCount == 1)
    }

    @Test("renderer failure fences an already-running local session")
    func rendererFailureAfterSessionStartIsRetryable() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }

        #expect(await fixture.controller.startIfNeeded(columns: 80, rows: 24))
        #expect(fixture.controller.state == .running)

        // A controller survives a terminal view remount. A renderer failure on
        // that later mount must close the old pty and expose an explicit retry,
        // rather than leaving the state as running behind a black view.
        fixture.controller.markRendererFailure()

        #expect(fixture.controller.state == .failed)
        #expect(fixture.controller.canRetry)
        #expect(fixture.controller.lastError == .rendererUnavailable)
        var hangups = fixture.kernel.hangups.makeAsyncIterator()
        #expect(await hangups.next() != nil)
        #expect(fixture.kernel.hangupCount == 1)
    }

    @Test("kernel boot failures are sticky while pty open failures can retry")
    func failureRetryRules() async throws {
        let bootFailure = try ControllerFixture(
            boot: { _, _ in throw LocalLinuxKernelBridgeError.bootFailed(errno: -5) }
        )
        defer { bootFailure.remove() }
        #expect(await bootFailure.controller.startIfNeeded() == false)
        #expect(bootFailure.controller.state == .failed)
        #expect(bootFailure.controller.lastError == .bootFailed(errno: -5))
        #expect(bootFailure.controller.canRetry == false)
        #expect(await bootFailure.controller.startIfNeeded() == false)

        let openFailure = try ControllerFixture(
            open: { _, _, _, _, _, _, _ in
                throw LocalLinuxKernelBridgeError.sessionOpenFailed(errno: -12)
            }
        )
        defer { openFailure.remove() }
        #expect(await openFailure.controller.startIfNeeded() == false)
        #expect(openFailure.controller.state == .failed)
        #expect(openFailure.controller.lastError == .sessionOpenFailed(errno: -12))
        #expect(openFailure.controller.canRetry)
    }

    @Test("the shell configuration reaches the kernel bridge unchanged")
    func shellConfigurationIsForwarded() async throws {
        let shell = LocalLinuxShellConfiguration(
            command: ["/bin/sh", "-l"],
            environment: ["TERM=xterm-256color", "LANG=C.UTF-8"]
        )
        let fixture = try ControllerFixture(shell: shell)
        defer { fixture.remove() }

        #expect(await fixture.controller.startIfNeeded(columns: 120, rows: 40))

        var opens = fixture.kernel.opens.makeAsyncIterator()
        let open = try #require(await opens.next())
        #expect(open.command == shell.command)
        #expect(open.environment == shell.environment)
        #expect(open.columns == 120)
        #expect(open.rows == 40)
    }

}

/// Records every kernel interaction and lets a test end the pty naturally.
private final class ControllerTestKernel: @unchecked Sendable {
    struct Open: Equatable, Sendable {
        let command: [String]
        let environment: [String]
        let columns: Int32
        let rows: Int32
    }

    private let lock = NSLock()
    private var openCountValue = 0
    private var hangupCountValue = 0
    let exitsImmediately: Bool

    let opens: AsyncStream<Open>
    let inputs: AsyncStream<Data>
    let hangups: AsyncStream<Void>
    private let openContinuation: AsyncStream<Open>.Continuation
    private let inputContinuation: AsyncStream<Data>.Continuation
    private let hangupContinuation: AsyncStream<Void>.Continuation

    init(exitsImmediately: Bool) {
        self.exitsImmediately = exitsImmediately
        let opens = AsyncStream<Open>.makeStream(bufferingPolicy: .unbounded)
        let inputs = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let hangups = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        self.opens = opens.stream
        self.inputs = inputs.stream
        self.hangups = hangups.stream
        openContinuation = opens.continuation
        inputContinuation = inputs.continuation
        hangupContinuation = hangups.continuation
    }

    var openCount: Int { lock.withLock { openCountValue } }
    var hangupCount: Int { lock.withLock { hangupCountValue } }

    func open(
        command: [String],
        environment: [String],
        columns: Int32,
        rows: Int32,
        output: @Sendable (Data) -> Void,
        onTermination: @Sendable () -> Void
    ) -> any LocalLinuxKernelSession {
        lock.withLock {
            openCountValue += 1
        }
        openContinuation.yield(Open(
            command: command,
            environment: environment,
            columns: columns,
            rows: rows
        ))
        output(Data("ready\n".utf8))
        if exitsImmediately {
            onTermination()
        }
        return LocalLinuxTestKernelSession(
            send: { [inputContinuation] data in
                inputContinuation.yield(data)
                return data.count
            },
            hangup: { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.hangupCountValue += 1 }
                self.hangupContinuation.yield(())
            }
        )
    }
}

@MainActor
private struct ControllerFixture {
    let baseURL: URL
    let kernel: ControllerTestKernel
    let controller: LocalLinuxComputerController

    init(
        shell: LocalLinuxShellConfiguration = .default,
        exitsImmediately: Bool = false,
        boot: @escaping LocalLinuxTestKernelBridge.BootHandler = { _, _ in },
        open: LocalLinuxTestKernelBridge.OpenSessionHandler? = nil
    ) throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxLocalLinuxControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        self.baseURL = baseURL
        let archiveURL = baseURL.appendingPathComponent("alpine.tar.gz")
        try Data("test archive".utf8).write(to: archiveURL)

        let kernel = ControllerTestKernel(exitsImmediately: exitsImmediately)
        self.kernel = kernel
        let bridge = LocalLinuxTestKernelBridge(
            importRootfs: { _, destinationPath in
                let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: destination.appendingPathComponent("data", isDirectory: true),
                    withIntermediateDirectories: true
                )
                try Data("meta".utf8).write(to: destination.appendingPathComponent("meta.db"))
            },
            boot: boot,
            openSession: open ?? { command, environment, columns, rows, output, onTermination, _ in
                kernel.open(
                    command: command,
                    environment: environment,
                    columns: columns,
                    rows: rows,
                    output: output,
                    onTermination: onTermination
                )
            }
        )
        let runtime = LocalLinuxRuntime(
            kernel: bridge,
            fileSystem: LocalLinuxFileSystemClient(),
            rootURL: baseURL.appendingPathComponent("root", isDirectory: true),
            rootfsArchiveURL: archiveURL,
            rootfsArchiveDigest: nil
        )
        controller = LocalLinuxComputerController(runtime: runtime, shell: shell)
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}
