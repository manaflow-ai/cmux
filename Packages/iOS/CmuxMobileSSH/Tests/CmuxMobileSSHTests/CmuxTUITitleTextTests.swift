@testable import CmuxMobileSSH
import Foundation
import Testing

/// A terminal shows its title's text (D2): the daemon announces no spinner
/// frame of the same text, so a phone that showed the raw title would keep the
/// first frame (`⠂ Task`) while the agent works.
@Suite struct CmuxTUITitleTextTests {
    /// `list-workspaces` tabs carry `title_text`; a daemon from before the
    /// split sends only `title`, which the phone keeps as is.
    @Test func treeTerminalsShowTheTitleText() throws {
        let json = #"""
        {"workspaces":[{"id":1,"key":"k","name":"1","active":true,"screens":[{"id":2,"panes":[{"id":3,"tabs":[
          {"surface":4,"kind":"pty","title":"⠐ Fix it","title_text":"Fix it","title_activity":"working"},
          {"surface":5,"kind":"pty","title":"vim"}]}]}]}]}
        """#
        let workspace = try #require(try CmuxTUITreeWire(cmuxTUILine: Data(json.utf8)).model.first)
        #expect(workspace.terminals.map(\.title) == ["Fix it", "vim"])
    }

    /// `title-changed` carries `text`; the phone shows it, not the raw frame.
    @Test func titleChangedShowsTheText() async throws {
        let peer = ScriptedCmuxTUIPeer()
        let control = try await peer.open(requestedSession: "main", reportedSession: "main")
        async let subscribed = control.subscribe()
        let request = try await peer.nextRequest()
        peer.reply(#"{"id":"\#(request["id"] as! String)","ok":true,"data":{}}"#)
        let events = try await subscribed
        peer.reply(#"{"event":"title-changed","surface":1,"title":"⠂ Fix it","text":"Fix it","activity":"working"}"#)
        peer.reply(#"{"event":"title-changed","surface":2,"title":"vim"}"#)
        peer.finish()
        var received: [CmuxTUIControlEvent] = []
        for await event in events { received.append(event) }
        #expect(received == [
            .titleChanged(surface: 1, title: "Fix it"),
            .titleChanged(surface: 2, title: "vim"),
            .disconnected,
        ])
    }
}
