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

    /// Review of cmux#55066: only a Cloud chat that went soon after its start puts its prompt back; one that ran
    /// for a while says only that it ended, and one a repick moved on (no start this run) gets no notice at all.
    @Test func theEndedSeedPutsThePromptBackOnlyForAChatThatWentSoonAfterItStarted() async throws {
        let opened = Date(timeIntervalSince1970: 1_000_000)
        let started = AgentPaneCloudStarted(
            start: AgentPaneCloudStart(task: "reply ok", cwd: "/tmp/p", key: UUID().uuidString),
            chat: "/tmp/p", workspace: nil, account: [], machineID: "vm_1", at: opened)

        let fresh = try #require(AgentPaneCloudStarted.endedSeed(started, machine: "box", now: opened.addingTimeInterval(30)))
        #expect(fresh.cloudChatEnded?.machine == "box")
        #expect(fresh.cloudChatEnded?.promptBack == true)
        #expect(await fresh.peek()?.draft == "reply ok")

        let later = opened.addingTimeInterval(AgentPaneCloudStarted.freshEnd + 1)
        let stale = try #require(AgentPaneCloudStarted.endedSeed(started, machine: "box", now: later))
        #expect(stale.cloudChatEnded?.promptBack == false)
        #expect(await stale.peek()?.draft == nil)

        #expect(AgentPaneCloudStarted.endedSeed(nil, machine: "box") == nil)
    }
}
