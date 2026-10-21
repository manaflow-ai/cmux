import AppKit
@testable import CmuxNextRemoteView
import Testing

@MainActor
struct RemoteDesktopPaneInputSinkTests {
    final class Recorder: RemoteViewInputSink {
        var events: [RemoteInputEvent] = []
        func send(_ event: RemoteInputEvent) { events.append(event) }
    }

    /// The input controller holds its sink weakly: a sink only the pane was
    /// given must stay alive, or control-mode input goes nowhere.
    @Test func paneKeepsItsInputSink() {
        let pane = RemoteDesktopPane(hostName: "mock", source: MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming)),
                                     inputSink: Recorder())
        #expect(pane.view.capture.controller.sink != nil)
    }
}
