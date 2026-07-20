import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohAdmittedConnectionSupervisorTests {
    @Test(arguments: ["control", "lanes", "together", "caller"])
    func firstExitClosesTheConnectionAndStopsLanesExactlyOnce(
        trigger: String
    ) async {
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
            },
            runApplicationLanes: {
                started.continuation.yield()
                for await _ in lanes.stream {}
                await childExitRecorder.record("lanes")
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
        switch trigger {
        case "control":
            control.continuation.finish()
        case "lanes":
            lanes.continuation.finish()
        case "together":
            control.continuation.finish()
            lanes.continuation.finish()
        default:
            runTask.cancel()
        }
        await runTask.value

        // One actor instance owns one admitted connection lifetime. A repeated
        // call cannot launch or clean up the same connection again.
        await supervisor.run()

        #expect(
            await cleanupRecorder.observedEvents()
                == ["connection.close", "lanes.stop"]
        )
        #expect(
            Set(await childExitRecorder.observedEvents())
                == Set(["control", "lanes"])
        )
    }
}
