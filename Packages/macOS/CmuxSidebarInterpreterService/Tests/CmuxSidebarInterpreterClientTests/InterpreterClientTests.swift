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
        let client = InterpreterClient(
            executableURL: interpreterWorkerURL(),
            timeout: .milliseconds(400),
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
