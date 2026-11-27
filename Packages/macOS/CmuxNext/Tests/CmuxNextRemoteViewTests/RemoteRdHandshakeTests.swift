import Foundation
@testable import CmuxNextRemoteView
import Testing

/// The viewer's session setup, whose rules live in Rust (cmux-rd-ffi `view/handshake.rs`):
/// this suite checks the Swift caller reads the Rust state back. The rule cases themselves are
/// the Rust parity tests (`view_transport_tests.rs`).
@Suite struct RemoteRdHandshakeTests {
    private static let welcome = Data(
        #"{"t":"welcome","encoder":"h264","width":1280,"height":800,"max_datagram":1200,"carrier":"stream","service":"desktop","caps":["cursor"]}"#.utf8
    )
    private static let started = Data(#"{"t":"started","session":7}"#.utf8)

    @Test func welcomeThenStartedStreams() {
        var handshake = RemoteRdHandshake(service: "desktop")
        #expect(handshake.sessionState == .connecting)
        handshake.receive(Self.welcome)
        #expect(handshake.phase == .awaitingStarted)
        #expect(handshake.welcome?.maxDatagram == 1200)
        #expect(handshake.welcome?.caps == ["cursor"])
        handshake.receive(Self.started)
        #expect(handshake.phase == .streaming(session: 7))
        #expect(handshake.sessionState == .streaming)
    }

    /// The Swift reducer listed every side message but `cursor_shape`, so a host's first cursor
    /// shape ended the session as a protocol error. It passes now.
    @Test func aCursorShapeDoesNotEndTheSession() {
        var handshake = RemoteRdHandshake(service: "desktop")
        handshake.receive(Self.welcome)
        handshake.receive(Self.started)
        handshake.receive(Data(#"{"t":"cursor_shape","shape":1,"width":1,"height":1,"hot_x":0,"hot_y":0,"rgba":"AAAAAA=="}"#.utf8))
        #expect(handshake.phase == .streaming(session: 7))
    }

    @Test func aWelcomeForAnotherServiceEndsTheSession() {
        var handshake = RemoteRdHandshake(service: "desktop")
        handshake.receive(Data(#"{"t":"welcome","encoder":"h264","width":1,"height":1,"max_datagram":1200,"carrier":"stream","service":"browser"}"#.utf8))
        #expect(handshake.phase == .ended(.connectionLost))
    }

    @Test func aCloseAfterStopIsTheViewersStop() {
        var lost = RemoteRdHandshake(service: "desktop")
        lost.connectionClosed()
        #expect(lost.phase == .ended(.connectionLost))

        var stopped = RemoteRdHandshake(service: "desktop")
        stopped.viewerStopped()
        #expect(stopped.stopSent)
        stopped.connectionClosed()
        #expect(stopped.phase == .ended(.stoppedByViewer))
    }

    @Test func refusedIsConsentDenied() {
        var handshake = RemoteRdHandshake(service: "desktop")
        handshake.receive(Data(#"{"t":"refused","reason":"no"}"#.utf8))
        #expect(handshake.phase == .ended(.consentDenied))
    }
}
