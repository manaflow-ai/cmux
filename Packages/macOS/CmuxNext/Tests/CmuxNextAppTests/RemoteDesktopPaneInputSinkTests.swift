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

    /// Only input that reaches the host counts as the person using the desktop: nothing while the
    /// capture is off (a watching session), one call per input while it is on.
    @Test func paneReportsThePersonsInputOnlyWhenItIsSent() {
        let sink = Recorder()
        let pane = RemoteDesktopPane(hostName: "mock", source: MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming)),
                                     inputSink: sink)
        var reported = 0
        pane.handlers.personInput = { reported += 1 }
        let controller = pane.view.capture.controller
        controller.pointer((x: 1, y: 1))
        #expect(reported == 0)
        #expect(sink.events.isEmpty)
        controller.isActive = true
        controller.pointer((x: 2, y: 2))
        #expect(reported == 1)
        #expect(sink.events.count == 1)
    }
}
