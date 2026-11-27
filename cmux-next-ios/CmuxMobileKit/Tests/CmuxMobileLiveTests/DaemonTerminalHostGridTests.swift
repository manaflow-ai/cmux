import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// PROTOCOL.md "Terminal sizing policy": the Mac's policy can keep a shared
/// terminal at a grid wider than the phone's. The session tells the screen
/// the Mac's columns before any byte drawn for them, so the mirror is never
/// fed a wider grid's output at the phone's width (garbled text), and the
/// phone says it renders such a grid (`host-grid-view-v1`), so the daemon
/// stops capping the PTY at the phone's viewport.
@MainActor @Suite struct DaemonTerminalHostGridTests {
    @Test func theMacsColumnsAreKnownBeforeTheBytesDrawnForThem() {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        #expect(session.remoteColumns == nil)
        var seen: [(event: TerminalSessionEvent, columns: Int?)] = []
        session.start { seen.append(($0, session.remoteColumns)) }
        session.handle(FakeTerminalDaemon.line(["event": "vt-state", "surface": 7, "cols": 120, "rows": 40,
                                                "data": Data("wide".utf8).base64EncodedString()]))
        #expect(seen.last?.event == .output(Data("wide".utf8)))
        #expect(seen.last?.columns == 120)
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 50, "rows": 20,
                                                "replay": Data("narrow".utf8).base64EncodedString()]))
        let reset = seen.firstIndex { $0.event == .output(Data("\u{1B}c".utf8)) }
        #expect(reset.map { seen[$0].columns } == 50, "the reset already has the new columns")
        #expect(seen.last?.event == .output(Data("narrow".utf8)))
        #expect(session.remoteColumns == 50)
        #expect(session.remoteRows == 20)
    }

    /// Review finding 8: a change of the Mac's columns reaches the screen as
    /// its own event, in order with the bytes, even with no output after it.
    @Test func aColumnsChangeIsAnEventInOrderWithTheBytes() {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var seen: [TerminalSessionEvent] = []
        session.start { seen.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "vt-state", "surface": 7, "cols": 120, "rows": 40,
                                                "data": Data("wide".utf8).base64EncodedString()]))
        let columns = seen.firstIndex(of: .hostGrid(columns: 120, rows: 40))
        let bytes = seen.firstIndex(of: .output(Data("wide".utf8)))
        #expect(columns != nil && bytes != nil && columns! < bytes!)
        seen.removeAll()
        session.handle(FakeTerminalDaemon.line(["event": "vt-state", "surface": 7, "cols": 120, "rows": 40, "data": ""]))
        #expect(!seen.contains(.hostGrid(columns: 120, rows: 40)), "the same grid again is not a change")
        session.handle(FakeTerminalDaemon.line(["event": "vt-state", "surface": 7, "cols": 90, "rows": 40, "data": ""]))
        #expect(seen.contains(.hostGrid(columns: 90, rows: 40)))
        // Review 2 finding 6: the rows travel with the columns, in byte order.
        seen.removeAll()
        session.handle(FakeTerminalDaemon.line(["event": "vt-state", "surface": 7, "cols": 90, "rows": 20, "data": ""]))
        #expect(seen.contains(.hostGrid(columns: 90, rows: 20)), "a rows change alone is a grid change")
    }

    /// Review finding 7: the letterbox note follows the size state, not the
    /// next layout or output.
    @Test func theGridOwnerIsAnEventWhenTheSizeStateChanges() {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var seen: [TerminalSessionEvent] = []
        session.start { seen.append($0) }
        func state(_ generation: Int, owner: String) -> Data {
            FakeTerminalDaemon.line(["event": "size-state", "surface": 7, "state": [
                "generation": generation, "cols": 120, "rows": 40, "reason": "priority", "owners": [owner],
                "policy": ["mode": "priority", "priority": [], "fixed": NSNull()],
                "participants": [
                    ["id": "c1", "device_kind": "mac", "device_name": "Mac mini", "viewport": ["cols": 120, "rows": 40], "counts": true],
                    ["id": "c2", "device_kind": "iphone", "device_name": "Other iPhone", "viewport": ["cols": 60, "rows": 30], "counts": true],
                ],
            ] as [String: Any]])
        }
        session.handle(state(1, owner: "c1"))
        #expect(seen.last == .hostGridOwner("Mac mini"))
        session.handle(state(2, owner: "c2"))
        #expect(seen.last == .hostGridOwner("Other iPhone"))
    }

    /// Leo, 2026-11-15, on his phone: "39x26 set by another device thing? ...
    /// its not accurtae". Under Fit the Smallest Viewer a narrow Mac pane set
    /// the columns and the phone the rows; the phone owning one dimension made
    /// the note say "another device" instead of naming the Mac.
    @Test func aGridThePhoneSharesNamesTheOtherOwner() {
        let session = DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone", "device_id": "me"]) {
            throw LinkError(code: "unused", message: "")
        }
        var seen: [TerminalSessionEvent] = []
        session.start { seen.append($0) }
        func state(_ generation: Int, owners: [String], participants: [[String: Any]]) -> Data {
            FakeTerminalDaemon.line(["event": "size-state", "surface": 7, "self_participant": "p1", "state": [
                "generation": generation, "cols": 39, "rows": 26, "reason": "smallest", "owners": owners,
                "policy": ["mode": "smallest", "priority": [], "fixed": NSNull()],
                "participants": participants,
            ] as [String: Any]])
        }
        let phone: [String: Any] = ["id": "p1", "device_kind": "iphone", "device_name": "Leo's iPhone",
                                    "device_id": "me", "viewport": ["cols": 54, "rows": 26], "counts": true]
        let mac: [String: Any] = ["id": "m1", "device_kind": "mac", "device_name": "Leo's MacBook Pro",
                                  "viewport": ["cols": 39, "rows": 40], "counts": true]
        session.handle(state(1, owners: ["p1", "m1"], participants: [phone, mac]))
        #expect(seen.last == .hostGridOwner("Leo's MacBook Pro"), "the phone sets the rows, the Mac pane the columns")
        // An unnamed Mac view is named by its kind, not "another device".
        var unnamed = mac
        unnamed["device_name"] = nil
        session.handle(state(2, owners: ["p1", "m1"], participants: [phone, unnamed]))
        #expect(seen.last == .hostGridOwner("a Mac"))
        // Another view of this same phone is this iPhone.
        var twin = phone
        twin["id"] = "p2"
        session.handle(state(3, owners: ["p2"], participants: [phone, twin]))
        #expect(seen.last == .hostGridOwner("this iPhone"))
        // The phone alone owns it: no other device to name.
        session.handle(state(4, owners: ["p1"], participants: [phone, mac]))
        #expect(seen.last == .hostGridOwner(nil))
    }

    @Test func thePhoneSaysItRendersTheMacsGrid() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let info = try #require(daemon.recorded.first { $0["cmd"] as? String == "set-client-info" })
        let capabilities = info["capabilities"] as? [String] ?? []
        #expect(capabilities.contains("host-grid-view-v1"))
        #expect(capabilities.contains("size-lease-v1"))
    }

    /// The suite's other tests' wait (DaemonTerminalSizeClaimTests): the
    /// fake daemon answers on its own task.
    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
