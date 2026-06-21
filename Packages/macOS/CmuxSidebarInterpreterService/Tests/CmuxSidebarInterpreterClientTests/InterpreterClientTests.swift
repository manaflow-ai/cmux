import CmuxSwiftRender
import Foundation
import Testing
@testable import CmuxSidebarInterpreterClient

@Suite struct InterpreterClientTests {
    @Test func rendersValidSourceOutOfProcess() async {
        let client = InterpreterClient(executableURL: interpreterWorkerURL(), timeout: .seconds(10))
        let node = await client.render(source: "Text(\"hello\")", state: [:])
        await client.shutdown()
        #expect(node?.kind == .text)
        #expect(node?.text == "hello")
    }

    @Test func bindsHostDataContextInTheWorker() async {
        let client = InterpreterClient(executableURL: interpreterWorkerURL(), timeout: .seconds(10))
        let node = await client.render(source: "Text(title)", state: ["title": .string("from-host")])
        await client.shutdown()
        #expect(node?.text == "from-host")
    }

    /// The headline guarantee: a worker that crashes mid-interpret returns
    /// `nil` to the host (it does NOT crash this test process), and the client
    /// transparently relaunches the worker for the next render.
    @Test func survivesAWorkerCrashAndRecovers() async {
        let crashToken = "__CRASH_THE_WORKER__"
        let client = InterpreterClient(
            executableURL: interpreterWorkerURL(),
            timeout: .seconds(10),
            environment: ["CMUX_INTERPRETER_TEST_CRASH_TOKEN": crashToken]
        )

        let crashed = await client.render(source: crashToken, state: [:])
        #expect(crashed == nil)

        let recovered = await client.render(source: "Text(\"still alive\")", state: [:])
        await client.shutdown()
        #expect(recovered?.text == "still alive")
    }

    /// A worker that hangs is killed at the deadline; the render returns `nil`
    /// and the next render relaunches a fresh worker.
    @Test func timesOutAHangingWorkerAndRecovers() async {
        let hangToken = "__HANG_THE_WORKER__"
        // `timeout` is a single per-render deadline applied to EVERY render on
        // this client, including the recovery render after the worker is killed.
        // A tight deadline (e.g. 400ms) makes the hang render fail fast, but it
        // also caps the recovery render — which must cold-spawn a fresh
        // subprocess and complete a full JSON-encode → stdin → render → stdout →
        // decode roundtrip. On a loaded CI host that cold spawn + first pipe
        // roundtrip can exceed 400ms, the watchdog fires on the recovery render,
        // and `recovered?.text == "after timeout"` fails nondeterministically.
        // Use a generous deadline so only the failure path is affected: the
        // worker hangs forever, so the timed-out render still returns nil (just
        // after the longer deadline), while the real cold-spawn recovery is no
        // longer racing a tight clock. This keeps same-client relaunch coverage
        // (the watchdog's `discardWorker()` path) intact.
        let client = InterpreterClient(
            executableURL: interpreterWorkerURL(),
            timeout: .seconds(10),
            environment: ["CMUX_INTERPRETER_TEST_HANG_TOKEN": hangToken]
        )

        let timedOut = await client.render(source: hangToken, state: [:])
        #expect(timedOut == nil)

        let recovered = await client.render(source: "Text(\"after timeout\")", state: [:])
        await client.shutdown()
        #expect(recovered?.text == "after timeout")
    }

    @Test func reusesOneWorkerAcrossManyRenders() async {
        let client = InterpreterClient(executableURL: interpreterWorkerURL(), timeout: .seconds(10))
        for index in 0..<8 {
            let node = await client.render(source: "Text(\"row \\(index)\")", state: ["index": .int(index)])
            #expect(node?.text == "row \(index)")
        }
        await client.shutdown()
    }
}
