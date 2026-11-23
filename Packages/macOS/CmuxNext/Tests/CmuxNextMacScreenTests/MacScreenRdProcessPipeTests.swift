import Foundation
@testable import CmuxNextMacScreen
import Testing

/// The Screen Sharing helper's lines reach the app after `startServe` returns (cmuxterm-hq#13721).
/// The helper is spawned on three pipes, not run by a `Process` that keeps them: when the pipes
/// went with the start's scope, the read end closed under its handler, the helper's key,
/// candidates and `candidates_done` went nowhere and no end of file came, so the viewer waited
/// at "Connecting..." forever. A shell stands in for the helper: it reads the setup line, waits
/// until the start has returned, then prints the lines the host prints.
@Suite struct MacScreenRdProcessPipeTests {
    static let key = String(repeating: "ab", count: 32)
    static let script = """
    read setup
    sleep 0.5
    printf '%s\\n' '{"displays":[[1920,1080]],"current":0}' '{"key":"\(key)"}' \
      '{"candidate":"host 192.168.1.4:51000"}' '{"candidates_done":true}'
    cat >/dev/null
    """

    /// The lines `process` prints, until `count` arrived, its end of file, or 10 s.
    static func lines(_ process: MacScreenRdProcess, count: Int) async -> [MacScreenRdMessage] {
        await withTaskGroup(of: [MacScreenRdMessage]?.self) { group in
            group.addTask {
                var read: [MacScreenRdMessage] = []
                for await line in process.lines {
                    read.append(line)
                    if read.count == count { break }
                }
                return read
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    @Test func aSpawnedHelpersLinesArriveAfterItsStartReturned() async throws {
        let process = MacScreenRdProcess()
        _ = try process.startSpawned { stdin, stdout, stderr in
            try MacScreenHelper.spawn(URL(fileURLWithPath: "/bin/sh"), ["-c", Self.script],
                                      stdin: stdin, stdout: stdout, stderr: stderr)
        }
        #expect(process.started)
        process.send(["session": "s"])
        let read = await Self.lines(process, count: 4)
        process.stop()
        #expect(read.count == 4)
        #expect(read.first?.displays == [[1920, 1080]])
        #expect(read.dropFirst().first?.key == Self.key)
        #expect(read.dropFirst(2).first?.candidate == "host 192.168.1.4:51000")
        #expect(read.last?.candidatesDone == true)
        #expect(read.map(\.kinds) == ["displays current", "key", "candidate", "candidates_done"])
    }
}
