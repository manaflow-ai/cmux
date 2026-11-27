import Foundation
import Testing
@testable import CmuxNextDaemon

/// The os-smoke WebKit flake (macOS 26 guests, about 1 run in 6): cmux-tui
/// answers `new-frontend-browser-tab` only after the tab's record is durable
/// (a full device flush under the registry lock), and on a guest whose disk
/// is busy (fsck_apfs, 118 MB/s) that took past the app's 2 s request
/// deadline. The app dropped the late reply, `action.run` failed, and the
/// tab the daemon made never got its page.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport. It
/// serves one request at a time per connection and makes one tab per
/// idempotency key, as cmux-tui does (its connection dispatcher and
/// `frontend-browser-tab-keys-v1`). It holds the first reply until the
/// app's deadline has passed and the next request arrives (the late commit),
/// then answers both in order. The create must succeed with the one tab.
struct FrontendBrowserTabLateReplyTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-browser-creates"
    }

    private static let script = #"""
    import json, sys
    keyed = sys.argv[1] == 'keyed'
    print('{"ok":true}', file=sys.stderr, flush=True)
    creates, tabs, held = [], {}, []
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def tab(frame):
        key = frame.get('idempotency_key') or 'unkeyed-%d' % len(creates)
        replayed = key in tabs
        if not replayed:
            tabs[key] = 40 + len(tabs)
        return {'surface': tabs[key], 'tab_resource_id': 'tab_%032x' % tabs[key], 'replayed': replayed}
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            caps = ['frontend-browser-tabs-v1'] + (['frontend-browser-tab-keys-v1'] if keyed else [])
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'late-reply-test', 'capabilities': caps})
        elif command == 'new-frontend-browser-tab':
            creates.append(frame)
            if len(creates) == 1:
                held.append(frame)  # the durable commit is still waiting on the disk
                continue
            for earlier in held:  # the commit ends; this connection's queue drains in order
                reply(earlier, tab(earlier))
            held.clear()
            reply(frame, tab(frame))
        elif command == 'test-browser-creates':
            reply(frame, {'creates': creates, 'tabs': len(tabs)})
        else:
            reply(frame, {})
    """#

    private func connection(keyed: Bool) -> DaemonConnection {
        let bridge = DaemonBridge.fakePython(["-c", Self.script, keyed ? "keyed" : "unkeyed"])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-late-reply-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), terminalEnvironment: nil))
    }

    @Test func aLateCreateReplyStillOpensTheOneTab() async throws {
        let connection = connection(keyed: true)
        try await connection.start()
        let created = try await connection.newFrontendBrowserTab(url: "http://127.0.0.1/webkit0", engine: .webkit, in: nil)
        let recorded = try await connection.request(Recorded())
        await connection.close()

        let creates = try #require(recorded["creates"]?.arrayValue)
        #expect(creates.count == 2, "the app asks again once the first reply is late")
        let keys = creates.map { $0["idempotency_key"]?.stringValue }
        #expect(keys[0] != nil && keys[0] == keys[1], "both requests carry the same key: \(keys)")
        #expect(recorded["tabs"]?.doubleValue == 1, "a retry with the key makes no second tab")
        #expect(created.surface == SurfaceID(rawValue: 40), "the create answers the tab the first request made")
    }

    @Test func aDaemonWithoutKeysIsNotAskedTwice() async throws {
        let connection = connection(keyed: false)
        try await connection.start()
        await #expect(throws: DaemonError.self) {
            try await connection.newFrontendBrowserTab(url: "http://127.0.0.1/webkit0", engine: .webkit, in: nil)
        }
        let recorded = try await connection.request(Recorded())
        await connection.close()
        let creates = try #require(recorded["creates"]?.arrayValue)
        #expect(creates.count == 1, "an unkeyed retry would make a second tab")
        #expect(creates[0]["idempotency_key"] == nil)
    }
}
