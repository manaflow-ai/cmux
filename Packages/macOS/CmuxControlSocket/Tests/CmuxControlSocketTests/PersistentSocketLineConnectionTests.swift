import Darwin
import Foundation
import Testing

@testable import CmuxControlSocket

@Suite(.serialized) struct PersistentSocketLineConnectionTests {
    @Test func commandsReuseOneAuthenticatedConnectionWithoutAddedLatency()
        async throws
    {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }
        let handled = UnixSocketFixture.acceptSingleClient(
            on: listenerFD
        ) { clientFD in
            for expected in ["first", "second"] {
                #expect(readLine(from: clientFD) == expected)
                let response = "\(expected)-response\n"
                #expect(SocketTransport().writeAll(
                    Data(response.utf8),
                    to: clientFD
                ))
            }
        }
        let connection = PersistentSocketLineConnection()
        let startedAt = ContinuousClock.now

        let first = await connection.command(
            "first",
            at: path,
            timeout: 0.5,
            validatingPeer: { $0 == getpid() }
        )
        let second = await connection.command(
            "second",
            at: path,
            timeout: 0.5,
            validatingPeer: { $0 == getpid() }
        )

        #expect(first?.response == "first-response")
        #expect(second?.response == "second-response")
        #expect(ContinuousClock.now - startedAt < .seconds(1))
        await connection.invalidate()
        let handledResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: handled.wait(timeout: .now() + 1.0)
                )
            }
        }
        #expect(handledResult == .success)
    }

    @Test func changingCommandTimeoutPreservesConnectionOwnership()
        async throws
    {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }
        let handled = UnixSocketFixture.acceptSingleClient(
            on: listenerFD
        ) { clientFD in
            for expected in ["start", "attach"] {
                #expect(readLine(from: clientFD) == expected)
                #expect(SocketTransport().writeAll(
                    Data("{\"ok\":true}\n".utf8),
                    to: clientFD
                ))
            }
        }
        let connection = PersistentSocketLineConnection()

        let start = await connection.command(
            "start",
            at: path,
            timeout: 0.5
        )
        let attach = await connection.command(
            "attach",
            at: path,
            timeout: 0.25
        )

        #expect(start?.response == "{\"ok\":true}")
        #expect(attach?.response == "{\"ok\":true}")
        await connection.invalidate()
        let handledResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: handled.wait(timeout: .now() + 1.0)
                )
            }
        }
        #expect(handledResult == .success)
    }

    @Test func stalledConnectionsDoNotStarveCooperativeTasks() async throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }
        #expect(Darwin.listen(listenerFD, 64) == 0)

        let commandReadStarted = DispatchSemaphore(value: 0)
        let stopServer = DispatchSemaphore(value: 0)
        let serverStopped = DispatchSemaphore(value: 0)
        DispatchQueue(
            label: "com.cmux.control-socket-tests.stalled-server",
            qos: .userInitiated
        ).async {
            var clientFDs: [Int32] = []
            defer {
                clientFDs.forEach { Darwin.close($0) }
                serverStopped.signal()
            }
            while stopServer.wait(timeout: .now()) == .timedOut {
                var descriptor = pollfd(
                    fd: listenerFD,
                    events: Int16(POLLIN),
                    revents: 0
                )
                guard Darwin.poll(&descriptor, 1, 10) > 0 else {
                    continue
                }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                if clientFD >= 0 {
                    clientFDs.append(clientFD)
                    #expect(readLine(from: clientFD) == "wait")
                    commandReadStarted.signal()
                }
            }
        }

        let cooperativeWorkerCount = max(
            ProcessInfo.processInfo.activeProcessorCount,
            2
        )
        let connections = (0..<(cooperativeWorkerCount * 2)).map { _ in
            PersistentSocketLineConnection()
        }
        let commands = connections.map { connection in
            Task.detached(priority: .userInitiated) {
                await connection.command(
                    "wait",
                    at: path,
                    timeout: 1
                )
            }
        }
        let blockersNeeded = cooperativeWorkerCount
        for _ in 0..<blockersNeeded {
            let commandReadResult = await wait(
                for: commandReadStarted,
                timeout: .now() + 2
            )
            #expect(
                commandReadResult == .success,
                "Expected enough stalled reads to occupy the cooperative pool"
            )
        }

        let probeCompleted = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            probeCompleted.signal()
        }
        let probeResult = await wait(
            for: probeCompleted,
            timeout: .now() + 1
        )
        #expect(
            probeResult == .success,
            "A stalled socket read must not occupy a cooperative executor thread"
        )

        stopServer.signal()
        let serverResult = await wait(
            for: serverStopped,
            timeout: .now() + 2
        )
        #expect(serverResult == .success)
        for command in commands {
            _ = await command.value
        }
    }

    @Test func trickledResponseBytesCannotExtendTheCommandDeadline()
        async throws
    {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }
        let handled = UnixSocketFixture.acceptSingleClient(
            on: listenerFD
        ) { clientFD in
            #expect(readLine(from: clientFD) == "trickle")
            _ = SocketTransport().configureNoSigPipe(clientFD)
            for _ in 0..<50 {
                guard SocketTransport().writeAll(
                    Data([0x78]),
                    to: clientFD
                ) else {
                    break
                }
                Darwin.usleep(25_000)
            }
        }
        let connection = PersistentSocketLineConnection()
        let startedAt = ContinuousClock.now

        let response = await connection.command(
            "trickle",
            at: path,
            timeout: 0.12
        )

        #expect(response == nil)
        #expect(ContinuousClock.now - startedAt < .milliseconds(600))
        await connection.invalidate()
        #expect(await wait(
            for: handled,
            timeout: .now() + 2
        ) == .success)
    }

    @Test func stalledCommandWritesCannotExtendTheDeadline() throws {
        let sockets = try UnixSocketFixture.makeSocketPair()
        defer {
            Darwin.close(sockets.reader)
            Darwin.close(sockets.writer)
        }
        var sendBufferByteCount: Int32 = 1_024
        #expect(withUnsafePointer(to: &sendBufferByteCount) { pointer in
            Darwin.setsockopt(
                sockets.writer,
                SOL_SOCKET,
                SO_SNDBUF,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        } == 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        let startedAt = ContinuousClock.now

        let wroteAll = SocketTransport().writeAll(
            Data(repeating: 0x78, count: 4 * 1_024 * 1_024),
            to: sockets.writer,
            deadline: deadline,
            isInterrupted: { false }
        )

        #expect(!wroteAll)
        #expect(ContinuousClock.now - startedAt < .milliseconds(500))
    }

    @Test func taskCancellationInterruptsAStalledResponseRead()
        async throws
    {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }
        let commandReceived = DispatchSemaphore(value: 0)
        let handled = UnixSocketFixture.acceptSingleClient(
            on: listenerFD
        ) { clientFD in
            #expect(readLine(from: clientFD) == "wait")
            commandReceived.signal()
            var byte: UInt8 = 0
            _ = Darwin.read(clientFD, &byte, 1)
        }
        let connection = PersistentSocketLineConnection()
        let command = Task {
            await connection.command(
                "wait",
                at: path,
                timeout: 5
            )
        }
        #expect(await wait(
            for: commandReceived,
            timeout: .now() + 1
        ) == .success)
        let startedAt = ContinuousClock.now

        command.cancel()
        let response = await command.value

        #expect(response == nil)
        #expect(ContinuousClock.now - startedAt < .milliseconds(500))
        await connection.invalidate()
        #expect(await wait(
            for: handled,
            timeout: .now() + 1
        ) == .success)
    }

    @Test func connectionEstablishmentHonorsTheCommandDeadline() async throws {
        let fixture = try makeBlockedConnectFixture()
        defer { Darwin.close(fixture.peerSocket) }
        let worker = makeWorker(connectDependencies: fixture.dependencies)
        let startedAt = ContinuousClock.now

        let response = await worker.command(
            "blocked-connect",
            at: "/unused/test.sock",
            timeout: 0.1,
            validatingPeer: { _ in true }
        )
        let elapsed = ContinuousClock.now - startedAt

        #expect(response == nil)
        #expect(elapsed < .milliseconds(400))
        await worker.invalidate()
    }

    @Test func taskCancellationInterruptsConnectionEstablishment() async throws {
        let connectStarted = DispatchSemaphore(value: 0)
        let fixture = try makeBlockedConnectFixture(
            connectStarted: connectStarted
        )
        defer { Darwin.close(fixture.peerSocket) }
        let worker = makeWorker(connectDependencies: fixture.dependencies)
        let command = Task {
            await worker.command(
                "blocked-connect",
                at: "/unused/test.sock",
                timeout: 5,
                validatingPeer: { _ in true }
            )
        }
        #expect(await wait(
            for: connectStarted,
            timeout: .now() + 1
        ) == .success)
        let startedAt = ContinuousClock.now

        command.cancel()
        let response = await command.value
        let elapsed = ContinuousClock.now - startedAt

        #expect(response == nil)
        #expect(elapsed < .milliseconds(400))
        await worker.invalidate()
    }

    @Test func invalidationInterruptsAStalledResponseRead()
        async throws
    {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }
        let commandReceived = DispatchSemaphore(value: 0)
        let handled = UnixSocketFixture.acceptSingleClient(
            on: listenerFD
        ) { clientFD in
            #expect(readLine(from: clientFD) == "wait")
            commandReceived.signal()
            var byte: UInt8 = 0
            _ = Darwin.read(clientFD, &byte, 1)
        }
        let connection = PersistentSocketLineConnection()
        let command = Task {
            await connection.command(
                "wait",
                at: path,
                timeout: 5
            )
        }
        #expect(await wait(
            for: commandReceived,
            timeout: .now() + 1
        ) == .success)
        let startedAt = ContinuousClock.now

        await connection.invalidate()
        let response = await command.value

        #expect(response == nil)
        #expect(ContinuousClock.now - startedAt < .milliseconds(500))
        #expect(await wait(
            for: handled,
            timeout: .now() + 1
        ) == .success)
    }

    @Test func invalidationRejectsCommandsAlreadyQueuedBehindAnActiveCommand()
        async throws
    {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }
        let commandEnqueued = DispatchSemaphore(value: 0)
        let activeCommandReceived = DispatchSemaphore(value: 0)
        let queuedCommandReceived = DispatchSemaphore(value: 0)
        let serverStopped = DispatchSemaphore(value: 0)
        DispatchQueue(
            label: "com.cmux.control-socket-tests.invalidation-barrier",
            qos: .userInitiated
        ).async {
            defer { serverStopped.signal() }
            let activeClient = Darwin.accept(listenerFD, nil, nil)
            guard activeClient >= 0 else { return }
            defer { Darwin.close(activeClient) }
            #expect(readLine(from: activeClient) == "active")
            activeCommandReceived.signal()
            var byte: UInt8 = 0
            _ = Darwin.read(activeClient, &byte, 1)

            var descriptor = pollfd(
                fd: listenerFD,
                events: Int16(POLLIN),
                revents: 0
            )
            guard Darwin.poll(&descriptor, 1, 500) > 0 else { return }
            let queuedClient = Darwin.accept(listenerFD, nil, nil)
            guard queuedClient >= 0 else { return }
            defer { Darwin.close(queuedClient) }
            if readLine(from: queuedClient) == "queued" {
                queuedCommandReceived.signal()
                #expect(SocketTransport().writeAll(
                    Data("unexpected-response\n".utf8),
                    to: queuedClient
                ))
            }
        }
        let worker = PersistentSocketLineConnectionWorker(
            transport: SocketTransport(),
            maximumResponseByteCount: 4_096,
            queue: DispatchQueue(
                label: "com.cmux.control-socket-tests.invalidation-worker"
            ),
            didEnqueueCommand: {
                commandEnqueued.signal()
            }
        )
        let active = Task {
            await worker.command(
                "active",
                at: path,
                timeout: 2,
                validatingPeer: { _ in true }
            )
        }
        #expect(await wait(
            for: commandEnqueued,
            timeout: .now() + 1
        ) == .success)
        #expect(await wait(
            for: activeCommandReceived,
            timeout: .now() + 1
        ) == .success)
        let queued = Task {
            await worker.command(
                "queued",
                at: path,
                timeout: 2,
                validatingPeer: { _ in true }
            )
        }
        #expect(await wait(
            for: commandEnqueued,
            timeout: .now() + 1
        ) == .success)

        await worker.invalidate()

        #expect(await active.value == nil)
        #expect(await queued.value == nil)
        #expect(await wait(
            for: serverStopped,
            timeout: .now() + 1
        ) == .success)
        #expect(await wait(
            for: queuedCommandReceived,
            timeout: .now()
        ) == .timedOut)
    }

    @Test func commandDeadlineIncludesTimeQueuedBehindAnActiveCommand()
        async throws
    {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }
        let commandEnqueued = DispatchSemaphore(value: 0)
        let activeCommandReceived = DispatchSemaphore(value: 0)
        let releaseActiveCommand = DispatchSemaphore(value: 0)
        let queuedCommandReceived = DispatchSemaphore(value: 0)
        let serverStopped = DispatchSemaphore(value: 0)
        DispatchQueue(
            label: "com.cmux.control-socket-tests.queued-deadline",
            qos: .userInitiated
        ).async {
            defer { serverStopped.signal() }
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }
            #expect(readLine(from: clientFD) == "active")
            activeCommandReceived.signal()
            _ = releaseActiveCommand.wait(timeout: .now() + 1)
            #expect(SocketTransport().writeAll(
                Data("active-response\n".utf8),
                to: clientFD
            ))

            var descriptor = pollfd(
                fd: clientFD,
                events: Int16(POLLIN),
                revents: 0
            )
            guard Darwin.poll(&descriptor, 1, 500) > 0 else { return }
            if readLine(from: clientFD) == "queued" {
                queuedCommandReceived.signal()
                #expect(SocketTransport().writeAll(
                    Data("queued-response\n".utf8),
                    to: clientFD
                ))
            }
        }
        let worker = PersistentSocketLineConnectionWorker(
            transport: SocketTransport(),
            maximumResponseByteCount: 4_096,
            queue: DispatchQueue(
                label: "com.cmux.control-socket-tests.queued-deadline-worker"
            ),
            didEnqueueCommand: {
                commandEnqueued.signal()
            }
        )
        let active = Task {
            await worker.command(
                "active",
                at: path,
                timeout: 2,
                validatingPeer: { _ in true }
            )
        }
        #expect(await wait(
            for: commandEnqueued,
            timeout: .now() + 1
        ) == .success)
        #expect(await wait(
            for: activeCommandReceived,
            timeout: .now() + 1
        ) == .success)
        let queued = Task {
            await worker.command(
                "queued",
                at: path,
                timeout: 0.1,
                validatingPeer: { _ in true }
            )
        }
        #expect(await wait(
            for: commandEnqueued,
            timeout: .now() + 1
        ) == .success)

        try await Task.sleep(for: .milliseconds(250))
        releaseActiveCommand.signal()

        #expect(await active.value?.response == "active-response")
        #expect(await queued.value == nil)
        #expect(await wait(
            for: serverStopped,
            timeout: .now() + 1
        ) == .success)
        #expect(await wait(
            for: queuedCommandReceived,
            timeout: .now()
        ) == .timedOut)
    }

    private func wait(
        for semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue(
                label: "com.cmux.control-socket-tests.semaphore-wait"
            ).async {
                continuation.resume(
                    returning: semaphore.wait(timeout: timeout)
                )
            }
        }
    }

    private func makeWorker(
        connectDependencies: PersistentSocketConnectDependencies
    ) -> PersistentSocketLineConnectionWorker {
        PersistentSocketLineConnectionWorker(
            transport: SocketTransport(),
            maximumResponseByteCount: 4_096,
            queue: DispatchQueue(
                label: "com.cmux.control-socket-tests.connect"
            ),
            connectDependencies: connectDependencies
        )
    }

    private func makeBlockedConnectFixture(
        connectStarted: DispatchSemaphore? = nil
    ) throws -> (
        dependencies: PersistentSocketConnectDependencies,
        peerSocket: Int32
    ) {
        let sockets = try UnixSocketFixture.makeSocketPair()
        do {
            try fillSendBuffer(of: sockets.writer)
        } catch {
            Darwin.close(sockets.reader)
            Darwin.close(sockets.writer)
            throw error
        }
        let socketSource = OneShotSocketSource(sockets.writer)
        let dependencies = PersistentSocketConnectDependencies(
            makeSocket: { socketSource.take() },
            connect: { socket, _ in
                connectStarted?.signal()
                let flags = Darwin.fcntl(socket, F_GETFL, 0)
                guard flags >= 0 else { return -1 }
                if flags & O_NONBLOCK == 0 {
                    Darwin.usleep(750_000)
                    Darwin.__error().pointee = ETIMEDOUT
                } else {
                    Darwin.__error().pointee = EINPROGRESS
                }
                return -1
            }
        )
        return (dependencies, sockets.reader)
    }

    private func fillSendBuffer(of socket: Int32) throws {
        let originalFlags = Darwin.fcntl(socket, F_GETFL, 0)
        guard
            originalFlags >= 0,
            Darwin.fcntl(
                socket,
                F_SETFL,
                originalFlags | O_NONBLOCK
            ) == 0
        else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer {
            _ = Darwin.fcntl(socket, F_SETFL, originalFlags)
        }
        let bytes = [UInt8](repeating: 0x78, count: 4_096)
        while true {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(socket, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
            return
        }
    }

    private func readLine(from socket: Int32) -> String? {
        var bytes: [UInt8] = []
        while bytes.count < 4_096 {
            var byte: UInt8 = 0
            let count = Darwin.read(socket, &byte, 1)
            guard count > 0 else { return nil }
            if byte == 0x0A {
                return String(data: Data(bytes), encoding: .utf8)
            }
            bytes.append(byte)
        }
        return nil
    }
}
