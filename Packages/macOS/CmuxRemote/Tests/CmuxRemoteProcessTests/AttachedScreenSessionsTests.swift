// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteScreenSharing
import CmuxRemoteWire
import CmuxVNCWebRTC
import Darwin
import Foundation
import Testing

/// The attached app's sessions in the Screen Sharing worker (docs/cmux-remote.md, "Attached
/// capture"): a cmux.rd/1 channel is the host process's stdio byte for byte, a WebRTC channel
/// relays signals, and the worker reports a running session as busy.
@Suite struct AttachedScreenSessionsTests {
    /// A connected pair: the worker's end as a LineChannel, the app's end as a raw descriptor.
    private static func pair() throws -> (worker: LineChannel, app: Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        return (LineChannel(socket: fds[0]), fds[1])
    }

    /// A stand-in cmux.rd/1 host: echoes each line it reads, and exits at end of file.
    private static func echoHost() throws -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "rd-echo-\(UUID().uuidString)").path
        let script = "#!/bin/sh\n[ \"$1\" = serve ] || exit 3\nexec /bin/cat\n"
        guard FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755]) else {
            throw POSIXError(.EIO)
        }
        return path
    }

    @Test func anRdChannelIsTheHostsStdio() throws {
        let host = try Self.echoHost()
        defer { try? FileManager.default.removeItem(atPath: host) }
        let sessions = AttachedScreenSessions(rdHost: host, logPath: "/dev/null")
        #expect(sessions.serves == [AttachedScreenHost.rdKind, AttachedScreenHost.webRTCKind])
        let (worker, app) = try Self.pair()
        let appChannel = LineChannel(socket: app)
        let thread = Thread {
            if let first = worker.readObject() { _ = sessions.take(first, channel: worker) }
        }
        thread.start()
        // The request and the host's first line in one write: nothing the app sends early is lost.
        #expect(appChannel.write(RemoteWire.line(["id": 1, "method": AttachedScreenHost.rdServe, "params": [:]]) + Data("{\"setup\":1}\n".utf8)))
        let answer = try #require(appChannel.readObject())
        #expect(answer["ok"] as? Bool == true)
        #expect(appChannel.readObject()?["setup"] as? Int == 1)
        #expect(sessions.serving == 1)
        #expect(appChannel.write(Data("{\"candidate\":\"c\"}\n".utf8)))
        #expect(appChannel.readObject()?["candidate"] as? String == "c")
        // The app's Stop: its write side closes, the host reads end of file and exits, the channel ends.
        _ = shutdown(app, SHUT_WR)
        #expect(appChannel.readObject() == nil)
        appChannel.close()
    }

    @Test func anotherFirstRequestIsNotAnAttachedSession() throws {
        let sessions = AttachedScreenSessions(rdHost: nil, logPath: "/dev/null")
        #expect(sessions.serves == [AttachedScreenHost.webRTCKind])
        let (worker, app) = try Self.pair()
        defer { worker.close(); Darwin.close(app) }
        #expect(!sessions.take(["id": 1, "method": "device.identity"], channel: worker))
        #expect(sessions.serving == 0)
    }

    @Test func aBundleWithoutTheRdHostRefusesAnRdChannel() throws {
        let sessions = AttachedScreenSessions(rdHost: nil, logPath: "/dev/null")
        let (worker, app) = try Self.pair()
        let appChannel = LineChannel(socket: app)
        defer { appChannel.close() }
        #expect(sessions.take(["id": 7, "method": AttachedScreenHost.rdServe], channel: worker))
        let answer = try #require(appChannel.readObject())
        #expect(answer["ok"] as? Bool == false)
        #expect(sessions.serving == 0)
    }

    /// The relay's signaling: the app's signals arrive in order, `signaling_closed` ends them, and
    /// closing this side tells the app without closing the channel.
    @Test func theWebRTCSignalingRelaysBothWays() async throws {
        let (worker, app) = try Self.pair()
        let appChannel = LineChannel(socket: app)
        defer { worker.close(); appChannel.close() }
        let signaling = AttachedChannelSignaling(channel: worker, servers: [ICEServerConfig(urls: ["stun:s.example.test"])])
        #expect(try await signaling.iceServers().first?.urls == ["stun:s.example.test"])
        signaling.feed(AttachedScreenHost.line(.offer("o")))
        signaling.feed(AttachedScreenHost.line(.candidate(ScreenICECandidate(candidate: "c", sdpMid: "0", sdpMLineIndex: 0))))
        signaling.feed(AttachedScreenHost.signalingClosed)
        var received: [ScreenSignal] = []
        for try await signal in signaling.messages() { received.append(signal) }
        #expect(received == [.offer("o"), .candidate(ScreenICECandidate(candidate: "c", sdpMid: "0", sdpMLineIndex: 0))])

        try await signaling.send(.answer("a"))
        #expect(AttachedScreenHost.signal(try #require(appChannel.readObject())) == .answer("a"))
        signaling.close()
        #expect(appChannel.readObject()?["signaling_closed"] as? Bool == true)
        try await signaling.send(.path(relay: false))
        #expect(AttachedScreenHost.signal(try #require(appChannel.readObject())) == .path(relay: false))
    }
}
