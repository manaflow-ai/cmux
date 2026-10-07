import Foundation
import Testing
@testable import CmuxNextRemoteView

/// The pane side of the C4b consent contract: share buttons only for a host
/// that offers upstream media, the permission prompt only from the button,
/// a denied permission opens nothing, the indicator shows each active kind
/// and its Stop (and hiding the tab) revokes at once.
@MainActor
struct RemoteUpstreamPaneStateTests {
    static func state(_ upstream: RemoteUpstreamStatus, _ session: RemoteSessionState = .streaming) -> RemotePaneState {
        var state = RemotePaneState(hostName: "h")
        state.status = RemoteViewStatus(state: session, upstream: upstream)
        return state
    }

    @Test func buttonsShowOnlyWhileStreamingFromAHostThatOffersUpstream() {
        #expect(Self.state(RemoteUpstreamStatus(offered: true)).showsUpstreamButtons)
        #expect(!Self.state(RemoteUpstreamStatus(offered: false)).showsUpstreamButtons)
        #expect(!Self.state(RemoteUpstreamStatus(offered: true), .connecting).showsUpstreamButtons)
        #expect(!RemotePaneState(hostName: "h").showsUpstreamButtons)
    }

    @Test func theIndicatorListsActiveKindsAndNothingOnceEnded() {
        let upstream = RemoteUpstreamStatus(offered: true, requested: [.camera], active: [.screen, .microphone])
        #expect(Self.state(upstream).upstreamIndicator == [.microphone, .screen])
        #expect(Self.state(upstream, .ended(.connectionLost)).upstreamIndicator.isEmpty)
    }

    @Test func stopHidesTheKindAtOnce() {
        let reducer = RemotePaneReducer()
        let upstream = RemoteUpstreamStatus(offered: true, requested: [.camera], active: [.microphone, .screen])
        let stopped = reducer.reduce(Self.state(upstream), .stopUpstream(.microphone))
        #expect(stopped.upstreamIndicator == [.screen])
        let all = reducer.reduce(stopped, .stopAllUpstreams)
        #expect(all.upstreamIndicator.isEmpty && all.upstream.requested.isEmpty)
        #expect(all.showsUpstreamButtons, "the host still offers upstream")
    }
}

/// Permission prompts recorded in order; the answer is fixed per test.
@MainActor
final class FakeUpstreamPermissions: RemoteUpstreamPermissions {
    var asked: [RemoteUpstreamKind] = []
    let answer: Bool

    init(answer: Bool) { self.answer = answer }

    func request(_ kind: RemoteUpstreamKind) async -> Bool {
        asked.append(kind)
        return answer
    }
}

#if DEBUG
@MainActor
struct RemoteUpstreamPaneTests {
    static func pane(offered: Bool, answer: Bool) -> (RemoteDesktopPane, MockRemoteStreamSource, FakeUpstreamPermissions) {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(
            state: .streaming, upstream: RemoteUpstreamStatus(offered: offered)
        ))
        let pane = RemoteDesktopPane(hostName: "h", source: source, inputSink: nil)
        let permissions = FakeUpstreamPermissions(answer: answer)
        pane.upstreamPermissions = permissions
        pane.upstreamControl = source
        return (pane, source, permissions)
    }

    /// Waits (bounded) until the pane state satisfies `done`.
    static func wait(_ pane: RemoteDesktopPane, _ done: (RemotePaneState) -> Bool) async {
        var tries = 0
        while !done(pane.state), tries < 400 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aGrantedPressSharesAndStopRevokes() async {
        let (pane, source, permissions) = Self.pane(offered: true, answer: true)
        pane.start()
        defer { pane.stop() }
        await Self.wait(pane) { $0.showsUpstreamButtons }
        #expect(permissions.asked.isEmpty, "no prompt before the user's action")
        pane.upstreamPressed(.microphone)
        await Self.wait(pane) { $0.upstreamIndicator == [.microphone] }
        #expect(permissions.asked == [.microphone])
        #expect(pane.state.upstreamIndicator == [.microphone])
        #expect(pane.view.upstreamIndicator.isHidden == false)
        // The indicator's Stop: hidden at once, revoked at the source.
        pane.view.upstreamIndicator.onStop?(.microphone)
        #expect(pane.state.upstreamIndicator.isEmpty)
        #expect(pane.view.upstreamIndicator.isHidden)
        await Self.wait(pane) { _ in source.currentStatus.upstream.active.isEmpty }
        #expect(source.currentStatus.upstream.active.isEmpty)
    }

    @Test func aDeniedPermissionSharesNothing() async {
        let (pane, source, permissions) = Self.pane(offered: true, answer: false)
        pane.start()
        defer { pane.stop() }
        await Self.wait(pane) { $0.showsUpstreamButtons }
        pane.upstreamPressed(.camera)
        await Self.wait(pane) { _ in !permissions.asked.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(permissions.asked == [.camera])
        #expect(source.currentStatus.upstream.active.isEmpty)
        #expect(pane.state.upstreamIndicator.isEmpty)
    }

    @Test func aHostWithoutUpstreamNeverPrompts() async {
        let (pane, _, permissions) = Self.pane(offered: false, answer: true)
        pane.start()
        defer { pane.stop() }
        await Self.wait(pane) { $0.status != nil }
        pane.upstreamPressed(.screen)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(permissions.asked.isEmpty)
    }

    @Test func hidingTheTabRevokesEveryKind() async {
        let (pane, source, _) = Self.pane(offered: true, answer: true)
        pane.start()
        await Self.wait(pane) { $0.showsUpstreamButtons }
        pane.upstreamPressed(.microphone)
        await Self.wait(pane) { $0.upstreamIndicator == [.microphone] }
        pane.stop()
        #expect(pane.state.upstreamIndicator.isEmpty)
        #expect(source.currentStatus.upstream.active.isEmpty)
    }
}
#endif
