@testable import CmuxNextBrowser
import Foundation
import Testing

/// The opt-in loopback DevTools endpoint for cmux on iPhone and its
/// `devtools.json` status file.
@Suite struct CEFRemoteDevToolsTests {
    func status(_ requested: Bool, port: UInt16?, started: Bool) -> CEFRemoteDevToolsStatus {
        CEFRemoteDevToolsStatus(requested: requested, port: port, started: started, pid: 42,
                                startedAt: Date(timeIntervalSince1970: 0))
    }

    func object(_ status: CEFRemoteDevToolsStatus) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: status.json()) as? [String: Any])
    }

    @Test func states() {
        #expect(status(false, port: nil, started: false).state == "off")
        #expect(status(false, port: nil, started: true).state == "off")
        #expect(status(true, port: nil, started: false).state == "waitingForBrowser")
        #expect(status(true, port: 50_000, started: false).state == "waitingForBrowser")
        #expect(status(true, port: 50_000, started: true).state == "ready")
        // The setting changed after Chromium started.
        #expect(status(true, port: nil, started: true).state == "restartRequired")
        #expect(status(false, port: 50_000, started: true).state == "restartRequired")
    }

    /// Only `ready` names a port, so a reader never uses an endpoint the person turned off.
    @Test func portOnlyWhenReady() throws {
        let ready = try object(status(true, port: 50_000, started: true))
        #expect(ready["port"] as? Int == 50_000)
        #expect(ready["enabled"] as? Bool == true)
        #expect(ready["pid"] as? Int == 42)
        #expect(ready["startedAt"] as? String == "1970-01-01T00:00:00Z")
        let turnedOff = try object(status(false, port: 50_000, started: true))
        #expect(turnedOff["port"] == nil)
        #expect(turnedOff["enabled"] as? Bool == false)
        let off = try object(status(false, port: nil, started: false))
        #expect(off["state"] as? String == "off")
        #expect(off["port"] == nil)
    }

    /// Each cmux tab id is paired with the target id its own browser reported, in ready only.
    @Test func targetsOnlyWhenReady() throws {
        var ready = status(true, port: 50_000, started: true)
        ready.targets = [CEFRemoteDevToolsTarget(tabID: "tab_a", targetID: "6F1C")]
        let object = try object(ready)
        let targets = try #require(object["targets"] as? [[String: String]])
        #expect(targets == [["tabId": "tab_a", "targetId": "6F1C"]])
        var off = ready
        off.requested = false
        #expect(try self.object(off)["targets"] == nil)
    }

    @Test func targetIDFromTargetInfo() {
        let bare = #"{"targetInfo":{"targetId":"ABC","type":"page","url":"https://example.com"}}"#
        #expect(CEFRemoteDevToolsStatus.targetID(fromTargetInfo: bare) == "ABC")
        let wrapped = #"{"id":1,"result":{"targetInfo":{"targetId":"DEF"}}}"#
        #expect(CEFRemoteDevToolsStatus.targetID(fromTargetInfo: wrapped) == "DEF")
        #expect(CEFRemoteDevToolsStatus.targetID(fromTargetInfo: #"{"targetInfo":{"targetId":""}}"#) == nil)
        #expect(CEFRemoteDevToolsStatus.targetID(fromTargetInfo: "not json") == nil)
    }

    @Test func fileIsOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "devtools.json")
        try status(true, port: 50_000, started: true).write(to: file)
        try status(false, port: nil, started: false).write(to: file)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(written["state"] as? String == "off")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["devtools.json"])
    }

    @Test func switchOnlyWhenRequested() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let off = CEFRemoteDevTools(statusFile: directory.appending(path: "devtools.json"))
        off.setRequested(false)
        #expect(off.startSwitches().isEmpty)

        let on = CEFRemoteDevTools(statusFile: directory.appending(path: "devtools.json"))
        on.setRequested(true)
        let switches = on.startSwitches()
        let port = try #require(on.status.port)
        #expect(switches == ["remote-debugging-port=\(port)"])
        #expect(!switches.contains { $0.contains("allow-origins") })
        on.contextInitialized()
        #expect(on.status.state == "ready")
    }

    func liveEndpoint(_ directory: URL) -> CEFRemoteDevTools {
        let devTools = CEFRemoteDevTools(statusFile: directory.appending(path: "devtools.json"))
        devTools.setRequested(true)
        _ = devTools.startSwitches()
        devTools.contextInitialized()
        return devTools
    }

    /// A fake in-process DevTools session: the first `failFirst` lookups of
    /// every method fail, later ones answer.
    @MainActor final class FakeSession {
        var failFirst: Int
        var calls: [String] = []
        init(failFirst: Int) { self.failFirst = failFirst }
        func call(_ browser: Int32, _ method: String) async throws -> String {
            calls.append(method)
            if calls.count <= failFirst { throw BrowserTabError.closed }
            return method == "Page.getFrameTree"
                ? #"{"frameTree":{"frame":{"id":"F\#(browser)","url":"https://example.com"}}}"#
                : #"{"targetInfo":{"targetId":"T\#(browser)"}}"#
        }
    }

    /// A lookup that fails is asked again on the browser's next event, and
    /// the mapping appears once the page answers.
    @Test func failedLookupRetriesOnTheNextEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let devTools = liveEndpoint(directory)
        let session = FakeSession(failFirst: 2)  // both methods fail on the first event
        await devTools.browserSeen(7, tabID: "tab_a", devTools: session.call)?.value
        #expect(devTools.status.targets.isEmpty)
        await devTools.browserSeen(7, tabID: "tab_a", devTools: session.call)?.value
        #expect(devTools.status.targets == [CEFRemoteDevToolsTarget(tabID: "tab_a", targetID: "F7")])
        // Mapped: later events ask nothing.
        #expect(devTools.browserSeen(7, tabID: "tab_a", devTools: session.call) == nil)
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "devtools.json"))) as? [String: Any]
        #expect((file?["targets"] as? [[String: String]]) == [["tabId": "tab_a", "targetId": "F7"]])
        devTools.browserClosed(7)
        #expect(devTools.status.targets.isEmpty)
    }

    /// The main frame id comes first; `Target.getTargetInfo` is the fallback.
    @Test func fallsBackToTargetInfo() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let devTools = liveEndpoint(directory)
        let session = FakeSession(failFirst: 1)  // Page.getFrameTree fails, Target.getTargetInfo answers
        await devTools.browserSeen(3, tabID: "tab_b", devTools: session.call)?.value
        #expect(devTools.status.targets == [CEFRemoteDevToolsTarget(tabID: "tab_b", targetID: "T3")])
        #expect(session.calls == ["Page.getFrameTree", "Target.getTargetInfo"])
    }

    /// Retries stop after a bound; with the setting off nothing is asked.
    @Test func retriesAreBoundedAndOffAsksNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let devTools = liveEndpoint(directory)
        let session = FakeSession(failFirst: .max)
        for _ in 0..<CEFRemoteDevTools.maxAttempts {
            await devTools.browserSeen(9, tabID: "tab_c", devTools: session.call)?.value
        }
        #expect(devTools.browserSeen(9, tabID: "tab_c", devTools: session.call) == nil)
        let off = CEFRemoteDevTools(statusFile: directory.appending(path: "off.json"))
        off.setRequested(false)
        off.contextInitialized()
        #expect(off.browserSeen(1, tabID: "tab_d", devTools: session.call) == nil)
        #expect(off.browserSeen(1, tabID: nil, devTools: session.call) == nil)
    }

    @Test func freePortIsNonZero() throws {
        let port = try #require(CEFRemoteDevTools.freeLoopbackPort())
        #expect(port > 1_023)
    }
}
