import Foundation
import Testing
@testable import CmuxNextMobile

@Suite struct MobileHostControlPipeTests {
    /// A complete burst fits in the OS pipe, but exceeds the old 256-line stream.
    /// Wait for the writer to exit before consuming the burst.
    @Test(.timeLimit(.minutes(1))) func allThousandQueuedControlLinesArrive() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try Self.script(in: directory, body: """
        echo ready
        read start
        i=0
        while [ "$i" -lt 1000 ]; do
          echo "$i"
          i=$((i + 1))
        done
        """)
        let child = MobileHostProcess()
        try child.start(MobileHostTests.launch(executable: script), environment: [:], log: nil)
        defer { child.stop() }
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        #expect(child.send(Data("start\n".utf8)))
        #expect(await child.waitForExit() == 0)
        var received: [String] = []
        while let line = await lines.next() { received.append(line) }
        #expect(received == (0..<1000).map(String.init))
    }

    /// The first token is held while hostd asks for it again and sends a pairing
    /// request. The request must arrive without a second token lookup or a wait.
    @Test(.timeLimit(.minutes(1))) func startupTokenRequestDoesNotRaceOrHoldPairing() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try Self.script(in: directory, body: """
        echo '{"type":"need_token"}'
        echo '{"type":"unpaired","phone_device_id":"test-phone"}'
        read token
        echo '{"type":"online","device_id":"d","team_id":"personal-u"}'
        while read line; do :; done
        """)
        let gate = TokenGate()
        let supervisor = MobileHostSupervisor()
        await supervisor.start(.init(launch: MobileHostTests.launch(executable: script), accessToken: { _ in
            await gate.fetch()
        }, acpmux: { nil }, log: nil))
        var pairing = supervisor.pairing.makeAsyncIterator()
        #expect(await pairing.next() == .unpaired(phoneDeviceID: "test-phone"))
        await gate.waitForFetch()
        #expect(await gate.calls == 1)
        await gate.release()
        for await state in supervisor.states where state.phase == .online { break }
        await supervisor.stop()
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-control-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func script(in directory: URL, body: String) throws -> URL {
        let script = directory.appendingPathComponent("host")
        try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

private actor TokenGate {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<String, Never>] = []
    private var started: CheckedContinuation<Void, Never>?

    func fetch() async -> String {
        calls += 1
        started?.resume()
        started = nil
        return await withCheckedContinuation { waiting.append($0) }
    }

    func waitForFetch() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        for continuation in waiting { continuation.resume(returning: "h.e.s") }
        waiting.removeAll()
    }
}
