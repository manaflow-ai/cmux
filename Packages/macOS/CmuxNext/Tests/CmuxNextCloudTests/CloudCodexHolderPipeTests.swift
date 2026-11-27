@testable import CmuxNextCloud
import Foundation
import Testing

/// The app's pipe to `cmux cloud codex-holder`: a holder started again opens with what the last
/// one knew, so it can end what that one delivered (cmux#37306 review).
@Suite(.timeLimit(.minutes(1)))
struct CloudCodexHolderPipeTests {
    /// A team switch that starts the next holder: its restore is for the team the last holder
    /// served, and the switch comes after it. Before, the restore named the new team, so the old
    /// team's machines were never taken back and the switch could not erase them.
    @Test func aRestartReplaysTheLastHoldersScopeBeforeTheLineThatStartedIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-holder-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Each child keeps the lines it read: the first ends after three (config, availability and
        // the list), the second after four.
        let script = folder.appendingPathComponent("holder")
        try Data("""
        #!/bin/sh
        n=$(cat '\(folder.path)/n' 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > '\(folder.path)/n'
        if [ "$n" = 1 ]; then head -n 3 > '\(folder.path)/child1'; else head -n 4 > '\(folder.path)/child2'; fi
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let (events, sink) = AsyncStream<CloudCodexHolderPipe.Event>.makeStream()
        let pipe = CloudCodexHolderPipe(binary: script, config: Data(#"{"op":"config"}"#.utf8), events: sink)
        let teamOne: [String: Any] = ["user": "u1", "team": "t1"], teamTwo: [String: Any] = ["user": "u1", "team": "t2"]
        let listed = try JSONSerialization.data(withJSONObject: ["op": "listed", "live": ["vm_1"], "current": teamOne])
        #expect(await pipe.send(.init(data: listed), acpmux: nil))
        var stream = events.makeAsyncIterator()
        while let event = await stream.next() {
            if case .ended(1, _) = event { break }
        }

        let switched = try JSONSerialization.data(withJSONObject: ["op": "scope_changed", "id": 7, "current": teamTwo])
        #expect(await pipe.send(.init(data: switched, id: 7), acpmux: nil))
        while let event = await stream.next() {
            if case .ended(2, let unanswered) = event {
                #expect(unanswered == [7])
                break
            }
        }

        let lines = try String(contentsOf: folder.appendingPathComponent("child2"), encoding: .utf8)
            .split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(lines.map { $0["op"] as? String } == ["config", "available", "restore", "scope_changed"])
        let team = { (line: [String: Any]) in (line["current"] as? [String: Any])?["team"] as? String }
        #expect(team(lines[1]) == "t1", "the fence opens under the last holder's scope")
        #expect(team(lines[2]) == "t1", "the restore is for the team the last holder served")
        #expect(lines[2]["live"] as? [String] == ["vm_1"])
        #expect(team(lines[3]) == "t2", "the switch comes after it")
    }

    /// A holder that ended between the caller's `isRunning` read and its send was started again
    /// with no acpmux path, and every transfer it ran then failed (cmux#37306 review): the pipe
    /// keeps the path it last had.
    @Test func aHolderStartedWithoutAPathGetsTheLastOne() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-holder-acpmux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("holder")
        try Data("""
        #!/bin/sh
        n=$(cat '\(folder.path)/n' 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > '\(folder.path)/n'
        if [ "$n" = 1 ]; then head -n 3 > '\(folder.path)/child1'; else head -n 4 > '\(folder.path)/child2'; fi
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let (events, sink) = AsyncStream<CloudCodexHolderPipe.Event>.makeStream()
        let pipe = CloudCodexHolderPipe(binary: script, config: Data(#"{"op":"config"}"#.utf8), events: sink)
        let team: [String: Any] = ["user": "u1", "team": "t1"]
        let acpmux = URL(fileURLWithPath: "/opt/acpmux")
        let first = try JSONSerialization.data(withJSONObject: ["op": "delivers", "id": 1, "current": team])
        #expect(await pipe.send(.init(data: first, id: 1), acpmux: acpmux))
        var stream = events.makeAsyncIterator()
        while let event = await stream.next() {
            if case .ended(1, _) = event { break }
        }

        let second = try JSONSerialization.data(withJSONObject: ["op": "delivers", "id": 2, "current": team])
        #expect(await pipe.send(.init(data: second, id: 2), acpmux: nil))
        while let event = await stream.next() {
            if case .ended(2, _) = event { break }
        }
        let lines = try String(contentsOf: folder.appendingPathComponent("child2"), encoding: .utf8)
            .split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(lines.map { $0["op"] as? String } == ["config", "available", "restore", "delivers"])
        #expect(lines[1]["acpmux"] as? String == acpmux.path)
    }

    /// A holder that writes faster than the app reads is ended, and that end still reaches the app
    /// though its lines filled the buffer: the requests it never answered fail, so a sign-out or quit
    /// never waits forever and a lifecycle request goes again (cmux#37306 review).
    @Test func aHolderThatOverflowsTheBufferStillReportsItsEnd() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-holder-flood-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("holder")
        try Data("""
        #!/bin/sh
        for i in 1 2 3 4 5 6 7 8 9 10; do echo '{"ask":"live","id":1}'; done
        exec sleep 30
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let (events, sink) = AsyncStream<CloudCodexHolderPipe.Event>.makeStream(bufferingPolicy: .bufferingOldest(3))
        let pipe = CloudCodexHolderPipe(binary: script, config: Data(#"{"op":"config"}"#.utf8), events: sink)
        let request = try JSONSerialization.data(withJSONObject: ["op": "sign_out", "id": 5])
        #expect(await pipe.send(.init(data: request, id: 5), acpmux: nil))
        // Read nothing until the holder is gone, so its lines fill the buffer.
        while await pipe.isRunning { await Task.yield() }
        var lines = 0
        for await event in events {
            switch event {
            case .line: lines += 1
            case .ended(let generation, let unanswered):
                #expect(generation == 1)
                #expect(unanswered == [5])
                #expect(lines == 2, "two lines, then the slot kept for the end")
                return
            }
        }
        Issue.record("the end never came")
    }
}
