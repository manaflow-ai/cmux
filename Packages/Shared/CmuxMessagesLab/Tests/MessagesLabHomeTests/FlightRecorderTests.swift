import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// MessagesLab's flight recorder in the Home pane: off unless the app's
/// policy turns it on, attached to the pane's window, and "Save Last 10
/// Seconds" writes the state ring under ~/Library/Logs/<app>/blink-<time>/,
/// with window captures only behind their own opt-in.
@MainActor @Suite(.serialized) struct FlightRecorderTests {
    private func pane() -> (NSWindow, HomeProjection, ChatController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (p, c) = Fixture2.projection()
        c.host.frame = NSRect(x: 0, y: 0, width: 628, height: 900)
        window.contentView = c.host
        p.apply(items: Fixture2.history(6), summary: Fixture2.summary(lastSeq: 6), typing: [], hasOlder: false)
        return (window, p, c)
    }

    private func reset() {
        HomeFlightRecorder.isEnabled = { false }
        HomeFlightRecorder.capturesWindow = { false }
        HomeFlightRecorder.logFolder = "cmux"
    }

    @Test func offByDefaultSoNothingIsSaved() {
        reset()
        let (window, _, _) = pane()
        defer { window.close() }
        #expect(FlightRecorder.enabled == false)
        #expect(HomeFlightRecorder.saveLastSeconds() == nil)
    }

    /// A conversation shorter than the pane leaves the space above its first
    /// row empty: that is no transcript gap (the first send in a new Chief
    /// conversation dumped "gap 80-881 pt" with 30 window captures).
    @Test func aShortConversationHasNoTranscriptGap() {
        reset()
        let (window, _, c) = pane()
        defer { window.close() }
        c.host.layoutSubtreeIfNeeded()
        c.demo.layoutIfNeeded()
        c.demo.collection.layoutIfNeeded()
        #expect(!c.demo.collection.visibleCells.isEmpty)
        #expect(HomeFlightRecorder.coverageGaps(c.demo).isEmpty, "\(HomeFlightRecorder.coverageGaps(c.demo))")
    }

    @Test func saveLastSecondsWritesTheRingUnderTheAppsLogFolder() throws {
        reset()
        let folder = "cmux-flight-test-\(UUID().uuidString.prefix(8))"
        let logs = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/\(folder)")
        defer { try? FileManager.default.removeItem(atPath: logs); reset() }
        HomeFlightRecorder.logFolder = folder
        HomeFlightRecorder.isEnabled = { true }
        let (window, p, _) = pane()
        defer { window.close() }
        p.apply(items: Fixture2.history(7), summary: Fixture2.summary(lastSeq: 7), typing: [], hasOlder: false)
        let dir = try #require(HomeFlightRecorder.saveLastSeconds())
        #expect(dir.hasPrefix(logs + "/blink-"))
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/meta.json"))) as? [String: Any]
        #expect(meta?["reason"] as? String == "Save Last 10 Seconds")
        let events = (meta?["events"] as? [[String: Any]] ?? []).compactMap { $0["event"] as? String }
        #expect(events.contains { $0.hasPrefix("receive k7") }, "the engine's actions reach the recorder: \(events)")
        #expect(FileManager.default.fileExists(atPath: dir + "/frames.ndjson"))
        // Captures are a separate opt-in: none were taken.
        let frames = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/frames")) ?? []
        #expect(frames.isEmpty)
    }
}
