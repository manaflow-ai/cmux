import Foundation
import Testing
@testable import CmuxNextDaemon

/// `new-frontend-browser-tab {pane, split}` (`frontend-browser-tab-split-v1`): a link opened to the
/// right is made in its new split in one daemon commit (user report 2026-10-20). The `split` field
/// is the conversation tab split's shape (`direction`, `pane_id`, `split_id`), sent only to a
/// daemon that serves it: an older one would ignore it and make the tab in the source pane.
struct FrontendBrowserTabSplitRequestTests {
    private static func fields(_ request: NewFrontendBrowserTabRequest) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("the request is not an object")
            return [:]
        }
        return fields
    }

    @Test func theSplitGoesOnTheWireWithTheClientMintedIDs() throws {
        let split = ConversationTabSplit(direction: .right, paneID: "pane_0123", splitID: "split_4567")
        let fields = try Self.fields(NewFrontendBrowserTabRequest(url: "https://example.com", engine: .webkit, pane: PaneID(rawValue: 3), split: split))
        #expect(fields["cmd"] == .string("new-frontend-browser-tab"))
        #expect(fields["pane"] == .number(3))
        #expect(fields["split"] == .object(["direction": .string("right"), "pane_id": .string("pane_0123"), "split_id": .string("split_4567")]))
    }

    @Test func noSplitSendsNoField() throws {
        let fields = try Self.fields(NewFrontendBrowserTabRequest(url: "https://example.com", engine: .webkit, pane: PaneID(rawValue: 3)))
        #expect(fields["split"] == nil)
        let down = ConversationTabSplit(direction: .down, paneID: "pane_0123", splitID: nil)
        let older = try Self.fields(NewFrontendBrowserTabRequest(url: "https://example.com", engine: .webkit, pane: PaneID(rawValue: 3), split: down))
        #expect(older["split"] == .object(["direction": .string("down"), "pane_id": .string("pane_0123")]),
                "a daemon without split-client-split-id-v1 gets no split_id")
    }

    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-browser-creates"
    }

    /// A scripted daemon that records every `new-frontend-browser-tab` (FrontendBrowserTabLateReplyTests).
    private static let script = #"""
    import json, sys
    splits = sys.argv[1] == 'splits'
    print('{"ok":true}', file=sys.stderr, flush=True)
    creates = []
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            caps = ['frontend-browser-tabs-v1'] + (['frontend-browser-tab-split-v1'] if splits else [])
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'split-test', 'capabilities': caps})
        elif command == 'new-frontend-browser-tab':
            creates.append(frame)
            reply(frame, {'surface': 40, 'tab_resource_id': 'tab_%032x' % 40})
        elif command == 'test-browser-creates':
            reply(frame, {'creates': creates})
        else:
            reply(frame, {})
    """#

    private func connection(splits: Bool) -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, splits ? "splits" : "older"])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-browser-split-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(2), terminalEnvironment: nil))
    }

    @Test func aDaemonThatSplitsGetsOneCreateWithTheSplit() async throws {
        let connection = connection(splits: true)
        try await connection.start()
        let split = ConversationTabSplit(direction: .right, paneID: "pane_0123", splitID: "split_4567")
        let created = try await connection.newFrontendBrowserTab(url: "https://example.com", engine: .webkit, in: PaneID(rawValue: 1), split: split)
        let recorded = try await connection.request(Recorded())
        await connection.close()
        let creates = try #require(recorded["creates"]?.arrayValue)
        #expect(creates.count == 1)
        #expect(creates.first?["split"]?["pane_id"]?.stringValue == "pane_0123")
        #expect(created.surface == SurfaceID(rawValue: 40))
    }

    @Test func anOlderDaemonIsNeverAskedForASplit() async throws {
        let connection = connection(splits: false)
        try await connection.start()
        let split = ConversationTabSplit(direction: .right, paneID: "pane_0123", splitID: nil)
        await #expect(throws: DaemonError.self) {
            try await connection.newFrontendBrowserTab(url: "https://example.com", engine: .webkit, in: PaneID(rawValue: 1), split: split)
        }
        let recorded = try await connection.request(Recorded())
        await connection.close()
        #expect(recorded["creates"]?.arrayValue?.isEmpty == true, "the older daemon would have made the tab in the source pane")
    }
}
