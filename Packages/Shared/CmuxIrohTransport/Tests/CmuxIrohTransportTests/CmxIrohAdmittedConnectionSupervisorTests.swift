import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohAdmittedConnectionSupervisorTests {
    @Test
    func applicationLaneExitCannotCloseAUsableControlConnection() async {
        let control = AsyncStream<Void>.makeStream()
        let lanes = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        var startedIterator = started.stream.makeAsyncIterator()
        let cleanupRecorder = TestIrohEventRecorder()
        let childExitRecorder = TestIrohEventRecorder()
        let supervisor = CmxIrohAdmittedConnectionSupervisor(
            runControl: {
                started.continuation.yield()
                for await _ in control.stream {}
                await childExitRecorder.record("control")
                return CmxIrohAdmittedConnectionExit(
                    lifecycle: .controlReadFailed,
                    failure: .transportIdleTimedOut
                )
            },
            runApplicationLanes: {
                started.continuation.yield()
                for await _ in lanes.stream {}
                await childExitRecorder.record("lanes")
                return CmxIrohAdmittedConnectionExit(
                    lifecycle: .applicationLaneFailed,
                    failure: .connectionClosed
                )
            },
            closeConnection: {
                await cleanupRecorder.record("connection.close")
            },
            stopApplicationLanes: {
                await cleanupRecorder.record("lanes.stop")
            }
        )
        let runTask = Task {
            await supervisor.run()
        }
        defer {
            runTask.cancel()
            control.continuation.finish()
            lanes.continuation.finish()
            started.continuation.finish()
        }

        #expect(await startedIterator.next() != nil)
        #expect(await startedIterator.next() != nil)
        lanes.continuation.finish()
        while await childExitRecorder.observedEvents() != ["lanes"] {
            await Task.yield()
        }
        #expect(await cleanupRecorder.observedEvents().isEmpty)

        control.continuation.finish()
        let exit = await runTask.value

        // One actor instance owns one admitted connection lifetime. A repeated
        // call cannot launch or clean up the same connection again.
        let repeatedExit = await supervisor.run()

        #expect(
            await cleanupRecorder.observedEvents()
                == ["connection.close", "lanes.stop"]
        )
        #expect(
            Set(await childExitRecorder.observedEvents())
                == Set(["control", "lanes"])
        )
        #expect(
            exit == CmxIrohAdmittedConnectionExit(
                lifecycle: .controlReadFailed,
                failure: .transportIdleTimedOut
            )
        )
        #expect(repeatedExit == exit)
    }

    @Test
    func callerCancellationStillClosesOwnedWorkExactlyOnce() async {
        let control = AsyncStream<Void>.makeStream()
        let lanes = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        var startedIterator = started.stream.makeAsyncIterator()
        let cleanupRecorder = TestIrohEventRecorder()
        let supervisor = CmxIrohAdmittedConnectionSupervisor(
            runControl: {
                started.continuation.yield()
                for await _ in control.stream {}
                return CmxIrohAdmittedConnectionExit(
                    lifecycle: .explicitlyInvalidated,
                    failure: .cancelled
                )
            },
            runApplicationLanes: {
                started.continuation.yield()
                for await _ in lanes.stream {}
                return CmxIrohAdmittedConnectionExit(
                    lifecycle: .explicitlyInvalidated,
                    failure: .cancelled
                )
            },
            closeConnection: {
                await cleanupRecorder.record("connection.close")
            },
            stopApplicationLanes: {
                await cleanupRecorder.record("lanes.stop")
            }
        )
        let runTask = Task { await supervisor.run() }
        defer {
            control.continuation.finish()
            lanes.continuation.finish()
            started.continuation.finish()
        }

        #expect(await startedIterator.next() != nil)
        #expect(await startedIterator.next() != nil)
        runTask.cancel()
        _ = await runTask.value

        #expect(
            await cleanupRecorder.observedEvents()
                == ["connection.close", "lanes.stop"]
        )
        _ = await supervisor.run()
        #expect(
            await cleanupRecorder.observedEvents()
                == ["connection.close", "lanes.stop"]
        )
    }
}
