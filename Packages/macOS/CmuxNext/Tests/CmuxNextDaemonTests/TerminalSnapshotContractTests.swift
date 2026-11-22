import Foundation
import Testing
@testable import CmuxNextDaemon

/// Wire contract with the host: cmux-tui writes its real snapshot event lines
/// for the dogfood case (a PNG Kitty image after scrollback; a plain READY with
/// history and images, then a local READY at a resize) to a checked-in file,
/// and this decoder reads the same file. A field either side changes breaks a
/// test on both sides instead of dropping events silently in the app.
@Suite struct TerminalSnapshotContractTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("cmux-tui/spec/fixtures/terminal-snapshot-dogfood-png.jsonl")

    @Test func everyHostSnapshotLineDecodes() throws {
        let text = try String(contentsOf: Self.fixture, encoding: .utf8)
        let lines = text.split(separator: "\n").map { Data($0.utf8) }
        var sequencer = TerminalSnapshotSequencer()
        var phases: [TerminalSnapshotFrame.Phase] = []
        var locals = 0
        var imageBytes = 0
        for line in lines {
            let name = try #require(Fixture.eventName(line))
            guard name == "snapshot" else { continue }
            let surface = try #require(TerminalAttachment.initialSurface(name: name, line: line))
            let decoded = try #require(TerminalAttachment.decodeAttachLine(name: name, line: line, surface: surface),
                                       "the view drops a host snapshot line: \(String(decoding: line.prefix(160), as: UTF8.self))")
            guard case .snapshot(let frame)? = sequencer.admit(decoded) else {
                Issue.record("the sequencer drops a host snapshot line of phase \(decoded)")
                continue
            }
            phases.append(frame.phase)
            if frame.localHistory != nil { locals += 1 }
            if frame.phase == .images { imageBytes += frame.data.count }
        }
        #expect(phases.first == .ready)
        #expect(phases.contains(.history))
        #expect(phases.contains(.images))
        #expect(imageBytes > 0)
        #expect(locals == 1, "the resize READY is a local-history READY with its check")
    }
}
