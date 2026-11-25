import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cmux#55066: a Mac tab whose Cloud chat went (its first turn failed on a used-up weekly limit, the machine
/// stopped) drew a blank new page. Its page now says the Cloud chat ended, where the message went and the ways
/// on, above the composer (``AgentPaneView/showCloudChatEnded(machine:promptBack:)``), and Dismiss closes it.
@Suite(.serialized)
@MainActor
struct AgentPaneCloudChatEndedNoticeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func pane() throws -> (AgentPaneView, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-ended-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        return (view, directory)
    }

    @Test func theNoticeNamesTheMachineAndTheWayOnAndDismissClosesIt() throws {
        let (view, directory) = try pane()
        defer { view.close(); try? FileManager.default.removeItem(at: directory) }
        #expect(view.paneNotices.isEmpty)

        view.showCloudChatEnded(machine: "cloud-chats-17", promptBack: true)
        let notice = try #require(view.paneNotices.first)
        #expect(notice.id == AgentPaneView.cloudChatEndedID)
        #expect(notice.title == AgentPaneView.cloudChatEndedTitle(machine: "cloud-chats-17"))
        #expect(notice.title.contains("cloud-chats-17"))
        #expect(notice.detail == AgentPaneView.cloudChatEndedDetail(promptBack: true))
        #expect(notice.button == AgentPaneView.cloudChatEndedDismiss)
        // What the page gets: the notice in the `paneNotices` event, with its button.
        guard case .object(let fields) = notice.value else { Issue.record("not an object"); return }
        #expect(fields["id"] == .string("cloudChatEnded"))
        #expect(fields["button"] == .string(AgentPaneView.cloudChatEndedDismiss))

        #expect(view.runPaneNoticeAction(AgentPaneView.cloudChatEndedID))
        #expect(view.paneNotices.isEmpty)
    }

    @Test func withNoMachineNameOrPromptItStillSaysWhatHappened() throws {
        let (view, directory) = try pane()
        defer { view.close(); try? FileManager.default.removeItem(at: directory) }
        view.showCloudChatEnded(machine: nil, promptBack: false)
        let notice = try #require(view.paneNotices.first)
        #expect(notice.title == AgentPaneView.cloudChatEndedTitle(machine: nil))
        #expect(notice.detail == AgentPaneView.cloudChatEndedDetail(promptBack: false))
        #expect(notice.detail != AgentPaneView.cloudChatEndedDetail(promptBack: true))
    }
}
