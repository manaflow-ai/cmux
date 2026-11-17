// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteScreenSharing
import CmuxRemoteWire
import Darwin
import Foundation
import Testing

/// The cmux app hands each Mac Screen session it serves to the Screen Sharing worker, which
/// captures as the helper (the app never asks macOS for Screen Recording or Accessibility). These
/// drive a real child over a real socket pair: `/bin/cat` stands in for `cmux-screen-sharing
/// serve`, so every line the app writes comes back as the host's line.
@Suite(.timeLimit(.minutes(1))) struct AttachedScreenSessionTests {
    /// The app's end of the channel and the worker's session.
    final class Rig {
        let app: LineChannel
        let session: AttachedScreenSession?
        private var events: AsyncStream<AttachedScreenSession.Event>.Iterator

        init(app: LineChannel, session: AttachedScreenSession?, events: AsyncStream<AttachedScreenSession.Event>) {
            self.app = app
            self.session = session
            self.events = events.makeAsyncIterator()
        }

        /// The session's next event, in order.
        func next() async -> AttachedScreenSession.Event? {
            await events.next()
        }

        /// The next line the worker wrote to the app, as an object (a blocking read, off this task).
        func read() async -> [String: Any]? {
            let app = app
            let line = await Task.detached { app.readLine() }.value
            return line.flatMap(RemoteWire.object)
        }
    }

    static func open(method: String = "session.rd", params: [String: Any] = ["session_id": "s1", "scope": "full",
                                                                              "viewer_id": "v1", "viewer_name": "Studio"],
                     headless: Bool, rdExecutable: String? = "/bin/cat") throws -> Rig {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        let worker = LineChannel(socket: pair[0])
        let (events, sink) = AsyncStream.makeStream(of: AttachedScreenSession.Event.self)
        let log = FileManager.default.temporaryDirectory.appending(path: "attached-\(UUID().uuidString).log").path
        let request = WorkerRequest(["id": 1, "method": method, "params": params])
        let session = AttachedScreenSession.open(request, channel: worker, headless: headless, rdExecutable: rdExecutable,
                                                 environment: ["PATH": "/usr/bin:/bin"], logPath: log) { event, _ in
            sink.yield(event)
        }
        return Rig(app: LineChannel(socket: pair[1]), session: session, events: events)
    }

    @Test func theRdHostIsTheWorkersChildAndItsLinesReachTheApp() async throws {
        let rig = try Self.open(headless: false)
        let answer = try #require(await rig.read())
        #expect(answer["ok"] as? Bool == true)
        let pid = try #require((answer["result"] as? [String: Any])?["pid"] as? Int)
        // Spawned by this process (the worker), so macOS attributes its capture to the helper.
        var info = proc_bsdinfo()
        #expect(proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0)
        #expect(info.pbi_ppid == UInt32(getpid()))

        rig.app.write(RemoteWire.line(["session": "s1", "peer_key": "k"]))
        let echoed = try #require(await rig.read())
        #expect(echoed["session"] as? String == "s1")

        rig.app.write(RemoteWire.line(["connected": true]))
        #expect(await rig.read()?["connected"] as? Bool == true)
        #expect(await rig.next() == .connected)
        #expect(rig.session?.connected == true)
    }

    @Test func theAppsStopEndsTheSession() async throws {
        let rig = try Self.open(headless: true)
        _ = await rig.read()
        rig.app.write(RemoteWire.line(["connected": true]))
        _ = await rig.read()
        #expect(await rig.next() == .connected)
        rig.app.write(RemoteWire.line(["stop": true]))
        guard case .ended = await rig.next() else { Issue.record("no end after the app's stop"); return }
    }

    /// The app quit with End Sharing When cmux Quits off: the connected session serves on, owned
    /// by the worker, until the worker stops it.
    @Test func aConnectedSessionOutlivesTheAppWhenHeadless() async throws {
        let rig = try Self.open(headless: true)
        _ = await rig.read()
        rig.app.write(RemoteWire.line(["connected": true]))
        _ = await rig.read()
        #expect(await rig.next() == .connected)
        rig.app.close()
        #expect(await rig.next() == .orphaned)
        rig.session?.stop()
        guard case .ended = await rig.next() else { Issue.record("no end after the worker's stop"); return }
    }

    @Test func theSessionStopsWithTheAppWhenNotHeadless() async throws {
        let rig = try Self.open(headless: false)
        _ = await rig.read()
        rig.app.write(RemoteWire.line(["connected": true]))
        _ = await rig.read()
        #expect(await rig.next() == .connected)
        rig.app.close()
        #expect(await rig.next() == .ended("the cmux app left"))
    }

    @Test func aHelperWithoutTheRdHostRefusesCmuxRdSessions() async throws {
        let rig = try Self.open(headless: true, rdExecutable: nil)
        #expect(rig.session == nil)
        let answer = try #require(await rig.read())
        #expect(answer["ok"] as? Bool == false)
        #expect((answer["error"] as? [String: Any])?["code"] as? String == "rd_unavailable")
    }

    @Test func aSessionNeedsAnIDAndAScope() async throws {
        let rig = try Self.open(params: ["session_id": "s1"], headless: true)
        #expect(rig.session == nil)
        #expect((await rig.read()?["error"] as? [String: Any])?["code"] as? String == "bad_request")
    }
}
