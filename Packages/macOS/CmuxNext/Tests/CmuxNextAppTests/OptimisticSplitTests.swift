@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Synchronization
import Testing

/// S3 (plans/cmux-next/remote-state-ownership.md): with `split-client-keys-v1` Cmd+D shows the
/// new pane before the daemon replies. T1 (app): the provisional pane is in the store while the
/// split is still in flight, and the request carries its client-minted ids. T2 (store frame
/// budget): it shows within one frame of the gesture, with a daemon that answers after 300 ms.
@MainActor @Suite(.timeLimit(.minutes(1))) struct OptimisticSplitTests {
    nonisolated static let replyDelay: TimeInterval = 0.3

    nonisolated static func tree() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "CmuxNextDaemonTests/Fixtures/list-workspaces.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let data = try JSONSerialization.data(withJSONObject: object?["data"] ?? [:])
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func daemon(tree: String, split: Mutex<[String: CmuxNextDaemon.JSONValue]?>)
        -> @Sendable ([String: CmuxNextDaemon.JSONValue]) -> [String] {
        { request in
            let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                let caps = (DaemonCapabilities.shared.required + [DaemonCapabilities.shared.splitClientKeys])
                    .map { "\"\($0)\"" }.joined(separator: ",")
                return [#"{"id":\#(id),"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"3412812eae76","protocol":12,"capabilities":[\#(caps)],"session":"local","pid":7,"registry_id":"r","generation":"g1","workspace_revision":0}}"#]
            case "list-workspaces":
                return [#"{"id":\#(id),"ok":true,"data":\#(tree)}"#]
            case "split":
                split.withLock { $0 = request }
                Thread.sleep(forTimeInterval: replyDelay)
                return [#"{"id":\#(id),"ok":true,"data":{"surface":92}}"#]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        }
    }

    @Test func aSplitShowsItsPaneWithinAFrameAndSendsTheClientIDs() async throws {
        let split = Mutex<[String: CmuxNextDaemon.JSONValue]?>(nil)
        let server = try ScriptedDaemonSocket(handler: Self.daemon(tree: try Self.tree(), split: split))
        let service = DaemonService()
        defer { server.stop(); service.shutdownConnection() }
        let path = server.path
        service.start(makeConnection: { DaemonConnection(endpoint: DaemonEndpoint(socketPath: path)) })
        try await waitForCondition(timeout: .seconds(10), sourceLocation: #_sourceLocation) { service.store.pane(16) != nil }
        let command = PaneSplitCommand(pane: 16, direction: .right, options: SpawnOptions(), swapTowards: nil)
        #expect(command.isOptimistic(on: service))
        let provisional = ProvisionalPane()
        let started = ContinuousClock.now
        let sent = Task { try await command.sendIntended(on: service, provisional: provisional) }
        while service.store.pane(provisional.handle) == nil, ContinuousClock.now - started < .seconds(1) {
            await Task.yield()
        }
        let shown = ContinuousClock.now - started
        #expect(service.store.pane(provisional.handle) != nil, "the provisional pane shows before the reply")
        #expect(shown < .milliseconds(17), "B1: the new pane shows within one 60 Hz frame (took \(shown))")
        _ = try await sent.value
        let request = try #require(split.withLock { $0 })
        #expect(request["pane_id"]?.stringValue == provisional.paneID)
        #expect(request["tab_id"]?.stringValue == provisional.tabID)
        #expect(request["terminal_id"]?.stringValue == provisional.terminalID)
    }

    @Test func aDaemonWithoutClientKeysTakesTheOldPath() throws {
        let service = DaemonService()
        let command = PaneSplitCommand(pane: 16, direction: .right, options: SpawnOptions(), swapTowards: nil)
        #expect(!command.isOptimistic(on: service))
        let left = PaneSplitCommand(pane: 16, direction: .right, options: SpawnOptions(), swapTowards: .right)
        #expect(!left.isOptimistic(on: service))
    }
}

/// T7 (S3): the view of a provisional pane's terminal attaches only once the daemon's terminal
/// is named; a closed view stops waiting.
@Suite struct TerminalTargetGateTests {
    @Test func theAttachWaitsForTheDaemonsTerminal() async {
        let gate = TerminalTargetGate()
        let waiting = Task { await gate.value() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!gate.isResolved)
        let target = TerminalAttachment.Target(surface: 92)
        gate.resolve(target)
        #expect(await waiting.value == target)
        gate.resolve(TerminalAttachment.Target(surface: 93))
        #expect(await gate.value() == target, "the first name wins")
    }

    @Test func aClosedViewStopsWaiting() async {
        let gate = TerminalTargetGate()
        let waiting = Task { await gate.value() }
        try? await Task.sleep(for: .milliseconds(20))
        gate.cancel()
        #expect(await waiting.value == nil)
    }
}
