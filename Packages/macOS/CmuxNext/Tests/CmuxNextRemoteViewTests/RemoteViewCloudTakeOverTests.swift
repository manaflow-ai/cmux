import AppKit
@testable import CmuxNextRemoteView
import Foundation
import Testing

/// A Cloud machine's `cmux-rd` desktop: shown in every build, opened watching, with one
/// Take over / Hand back button in the toolbar.
@MainActor
@Suite struct RemoteViewCloudTakeOverTests {
    private let policy = RemoteViewTabPolicy()

    @Test func aCloudRdDesktopConnectsInABuildWithoutTheDevelopmentPane() throws {
        let rd = try #require(RemoteViewTabRecord(host: "vm-0dd1c008", target: .virtual, mode: .view, cloudDesktop: true, cloudRd: true))
        #expect(policy.decide(record: rd, source: .person, paneAvailable: false) == .connect(rd))
        #expect(policy.decide(record: rd, source: .unconfirmed, paneAvailable: false) == .confirm(rd), "an agent's open still asks")
        #expect(policy.decide(record: rd, source: .remoteTree, paneAvailable: false) == .unavailable(.remoteRecord))
        #expect(policy.decide(record: rd, source: .person, paneAvailable: false, cloudRdAvailable: false) == .unavailable(.notInThisBuild))
        let vnc = try #require(RemoteViewTabRecord(host: "vm-0dd1c008", target: .virtual, mode: .view, cloudDesktop: true))
        #expect(policy.decide(record: vnc, source: .person, paneAvailable: false) == .unavailable(.notInThisBuild),
                "the VNC viewer stays development only")
        let mock = try #require(RemoteViewTabRecord(host: "mock"))
        #expect(policy.decide(record: mock, source: .person, paneAvailable: false) == .unavailable(.notInThisBuild))
        #expect(RemoteViewAvailability().isCloudRdAvailable)
    }

    @Test func restartForModeShowsReconnectingOverTheLastFrame() {
        var state = RemotePaneState(hostName: "vm", requestedMode: .control)
        let reducer = RemotePaneReducer()
        state = reducer.reduce(state, .status(RemoteViewStatus(state: .streaming)))
        state = reducer.reduce(state, .frameShown)
        let restarted = reducer.reduce(state, .restartForMode)
        #expect(restarted.sessionState == .connecting)
        #expect(restarted.reconnecting)
        #expect(!restarted.hasFrame)
        #expect(restarted.requestedMode == .control)
        var ended = state
        ended.status = RemoteViewStatus(state: .ended(.stoppedByViewer))
        #expect(reducer.reduce(ended, .restartForMode) == ended, "an ended session waits for Reconnect")
    }

    @Test func takeOverAndHandBackToggleTheMode() {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming))
        let pane = RemoteDesktopPane(hostName: "vm", source: source, inputSink: nil, initialMode: .view, viaCloudTunnel: true,
                                     modeControl: .takeOver)
        var asked: [RemoteControlMode] = []
        pane.handlers.selectMode = { asked.append($0) }
        pane.apply(.status(RemoteViewStatus(state: .streaming)))
        #expect(pane.view.toolbar.takeOverTitle == RemoteViewStrings.takeOver)
        #expect(pane.state.effectiveMode == .view, "a Cloud desktop opens watching")

        pane.view.toolbar.pressTakeOver()
        #expect(asked == [.control])
        #expect(pane.state.requestedMode == .control)
        #expect(pane.state.effectiveMode == .control)
        #expect(pane.view.toolbar.takeOverTitle == RemoteViewStrings.handBack)

        pane.view.toolbar.pressTakeOver()
        #expect(asked == [.control, .view])
        #expect(pane.state.requestedMode == .view)
        #expect(pane.view.toolbar.takeOverTitle == RemoteViewStrings.takeOver)

        pane.selectMode(.view)
        #expect(asked == [.control, .view], "the mode already in force changes nothing")
    }

    @Test func theToggleStaysForOtherDesktops() {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming))
        let pane = RemoteDesktopPane(hostName: "mock", source: source, inputSink: nil)
        pane.apply(.status(RemoteViewStatus(state: .streaming)))
        #expect(pane.view.toolbar.takeOverTitle == nil)
    }
}
