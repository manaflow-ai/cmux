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

        let accepted = DispatchSemaphore(value: 0)
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
                    accepted.signal()
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
            let acceptedResult = await wait(
                for: accepted,
                timeout: .now() + 2
            )
            #expect(
                acceptedResult == .success,
                "Expected enough stalled reads to occupy the cooperative pool"
            )
        }

        let probeCompleted = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            probeCompleted.signal()
        }
        let probeResult = await wait(
            for: probeCompleted,
            timeout: .now() + 0.2
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
