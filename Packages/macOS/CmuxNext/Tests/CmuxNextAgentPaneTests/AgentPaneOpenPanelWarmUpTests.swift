import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextTestSupport

/// The agent composer's + > Attach files or images is a page `<input type="file">` that
/// `PageOpenPanel` answers with the app's panel made ahead (`MadeAheadOpenPanel`). A new panel per
/// click showed its sheet 160 ms after the click, 830 ms for the process's first (capture-mini
/// bench, 2026-10-21); the panel made ahead shows it in 45 to 95 ms. So a chat that reaches a
/// window starts the warm-up, as Home's transcript does; a process that never ran the app's event
/// loop (this test host) still makes no panel.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct AgentPaneOpenPanelWarmUpTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aChatInAWindowWarmsThePickerAndMakesNoPanelInATestHost() async throws {
        _ = NSApplication.shared
        #expect(!NSApp.isRunning, "the test host runs no app event loop")
        // The pane's own panel, as the app passes its one (AppServices.openPanel): no other suite's warm-up shares it.
        let shared = MadeAheadOpenPanel()

        let directory = FileManager.default.temporaryDirectory.appending(path: "panel-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), openPanel: shared))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        let checks = shared.warmChecks
        window.contentView = view
        #expect(shared.isWarming, "a chat in a window did not start the picker's warm-up")

        let deadline = ContinuousClock.now + .seconds(20)
        while shared.warmChecks == checks || shared.isWarming, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(shared.warmChecks > checks && !shared.isWarming, "the warm-up never finished")
        #expect(!shared.isMade, "a panel was made ahead in a process that never ran the app")
    }
}
