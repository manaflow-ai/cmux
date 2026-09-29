import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSSH
import Foundation
import Testing
@testable import CmuxMobileShell

/// A paired cmux-next Mac's daemon, reached over an irx `daemon` lane, is a
/// lane computer: its cmux-tui workspaces become rows, a terminal attaches in
/// bytes mode, and typing reaches the daemon (plans/cmux-next/cloud-ios.md).
@MainActor
@Suite struct MobileSSHLaneComputerTests {
    @Test func laneComputerListsTheDaemonsWorkspaces() async throws {
        let (computers, sink, daemon, id) = makeLaneComputer()
        await computers.refreshLaneComputer(id: id)

        let state = try #require(sink.states.last)
        #expect(state.macDeviceID == MobileSSHIdentifier(computerOf: id).rawValue)
        #expect(state.displayName == "Studio Mac")
        #expect(state.status == .connected)
        #expect(state.workspaces.map(\.name) == ["api"])
        #expect(state.workspaces.first?.terminals.count == 1)
        #expect(computers.statusByHost[id] == .connected)
        #expect(computers.locallyServedComputerIDs.contains(state.macDeviceID))
        #expect(computers.locallyServedComputerNames[state.macDeviceID] == "Studio Mac")
        // Only the daemon's own kind; tmux and shells have no host to run on.
        let availability = computers.kindAvailability(hostID: id)
        #expect(availability.first { $0.kind == .cmuxTUI }?.isAvailable == true)
        #expect(availability.filter { $0.kind != .cmuxTUI }.allSatisfy { !$0.isAvailable })
        #expect(daemon.commands.contains("list-workspaces"))
        await computers.removeLaneComputer(id: id)
    }

    @Test func terminalAttachesInBytesModeAndInputReachesTheDaemon() async throws {
        let (computers, sink, daemon, id) = makeLaneComputer()
        await computers.refreshLaneComputer(id: id)
        let terminal = try #require(sink.states.last?.workspaces.first?.terminals.first)
        let surfaceID = terminal.id.rawValue

        computers.viewportChanged(surfaceID: surfaceID, columns: 90, rows: 30)
        computers.replay(surfaceID: surfaceID)
        try await sink.waitForOutput(surfaceID) { $0.contains("daemon-snapshot") }
        let attach = try #require(daemon.requests.first { $0["cmd"] as? String == "attach-surface" })
        #expect(attach["mode"] as? String == "bytes")
        #expect(attach["surface"] as? Int == 1)
        #expect(attach["cols"] as? Int == 90)

        computers.input(Data("echo hi\r".utf8), surfaceID: surfaceID)
        try await daemon.waitForCommand("send")
        let send = try #require(daemon.requests.last { $0["cmd"] as? String == "send" })
        #expect(send["bytes"] as? String == Data("echo hi\r".utf8).base64EncodedString())
        await computers.removeLaneComputer(id: id)
    }

    @Test func removingTheLaneComputerRemovesItsRows() async throws {
        let (computers, sink, _, id) = makeLaneComputer()
        await computers.refreshLaneComputer(id: id)
        await computers.removeLaneComputer(id: id)
        #expect(sink.removed == [MobileSSHIdentifier(computerOf: id).rawValue])
        #expect(computers.laneComputers[id] == nil)
        #expect(computers.statusByHost[id] == nil)
        #expect(!computers.locallyServedComputerIDs.contains(MobileSSHIdentifier(computerOf: id).rawValue))
    }

    @Test func tmuxAndShellsAreRefusedOnALaneComputer() async throws {
        let (computers, _, _, id) = makeLaneComputer()
        await computers.refreshLaneComputer(id: id)
        #expect(await computers.createWorkspace(hostID: id, kind: .shell) == nil)
        #expect(computers.statusByHost[id] == .failed(L10nSSH().laneKindUnavailable))
        await computers.removeLaneComputer(id: id)
    }

    @Test func laneComputerIDIsStablePerMac() {
        let first = MobileShellComposite.daemonLaneComputerID(macDeviceID: "mac-a")
        #expect(first == MobileShellComposite.daemonLaneComputerID(macDeviceID: "mac-a"))
        #expect(first != MobileShellComposite.daemonLaneComputerID(macDeviceID: "mac-b"))
    }

    /// The flag gates the lane end to end: without it (the default) the
    /// connected Mac never gets a lane computer, whatever it advertises.
    @Test func compositeAddsNoLaneComputerWhileTheFlagIsOff() {
        let store = MobileShellComposite.preview()
        store.configureDaemonLane(MobileDaemonLaneConfiguration(isEnabled: false) { _ in
            throw CancellationError()
        })
        store.supportedHostCapabilities = [MobileDaemonLaneFlag.capability]
        #expect(store.daemonLaneTarget == nil)
        #expect(store.sshComputers.laneComputers.isEmpty)
    }

    private func makeLaneComputer() -> (MobileSSHComputers, LaneRecordingSink, ScriptedDaemon, UUID) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-lane-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        let sink = LaneRecordingSink()
        computers.sink = sink
        let daemon = ScriptedDaemon()
        let id = UUID()
        computers.registerLaneComputer(id: id, name: "Studio Mac") { daemon.openCarrier() }
        return (computers, sink, daemon, id)
    }
}

@MainActor
final class LaneRecordingSink: MobileSSHComputersSink {
    var states: [MacWorkspaceState] = []
    var removed: [String] = []
    var outputs: [String: String] = [:]

    func sshPublishWorkspaceState(_ state: MacWorkspaceState) { states.append(state) }
    func sshRemoveWorkspaceState(computerID: String) { removed.append(computerID) }
    func sshDeliver(_ bytes: Data, surfaceID: String) {
        outputs[surfaceID, default: ""] += String(decoding: bytes, as: UTF8.self)
    }
    func sshApplyViewport(surfaceID: String) {}
    func sshReplaceBrowserPanels(workspaceID: String, with descriptors: [MobileBrowserPanelDescriptor]) {}
    func sshDeliverBrowserFrame(_ event: MobileBrowserFrameEvent) {}
    func sshDeliverBrowserState(_ event: MobileBrowserStateEvent) {}
    func sshBrowserStreamEnded(panelID: String, retry: Bool) {}

    func waitForOutput(_ surfaceID: String, until predicate: (String) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if predicate(outputs[surfaceID] ?? "") { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out; output so far: \(outputs[surfaceID] ?? "")")
        throw CancellationError()
    }
}

/// A cmux-tui daemon behind a lane: answers each request line the phone
/// writes with a recorded protocol-12 reply shape.
final class ScriptedDaemon: Sendable {
    private let state = LaneTestLocked<[[String: Any]]>([])

    var requests: [[String: Any]] { state.withLock { $0 } }
    var commands: [String] { requests.compactMap { $0["cmd"] as? String } }

    func openCarrier() -> any CmuxTUICarrier {
        ScriptedDaemonCarrier(daemon: self)
    }

    func record(_ request: [String: Any]) {
        state.withLock { $0.append(request) }
    }

    func waitForCommand(_ command: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if commands.contains(command) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("daemon never received \(command); saw \(commands)")
        throw CancellationError()
    }

    static let tree = #"{"workspace_revision":4,"workspaces":[{"id":4,"key":"6ba7b810-9dad-41d1-80b4-00c04fd430c8","resource_id":"ws_1","name":"api","active":true,"screens":[{"id":3,"name":null,"active":true,"active_pane":2,"layout":{"type":"leaf","pane":2},"panes":[{"id":2,"name":null,"active_tab":1,"focused_at":1,"tabs":[{"surface":1,"tab_resource_id":"tab_a","content_resource_id":"term_a","terminal_id":"t-1","terminal_resource_id":"term_a","kind":"pty","browser_source":null,"browser_status":null,"browser_error":null,"browser_frames_stalled":null,"url":null,"name":null,"title":"zsh","size":{"cols":80,"rows":24},"dead":false}]}]}]}]}"#

    /// The reply lines (plus any notifications that precede the reply).
    func replies(to request: [String: Any]) -> [String] {
        let id = request["id"] as? String ?? ""
        switch request["cmd"] as? String {
        case "identify":
            return [#"{"id":"\#(id)","ok":true,"data":{"app":"cmux-tui","version":"0.13.4","protocol":12,"capabilities":["workspace-registry-v1","attach-initial-size","view-attachment-lease-v1"],"session":"cmux-next","pid":1}}"#]
        case "list-workspaces":
            return [#"{"id":"\#(id)","ok":true,"data":\#(Self.tree)}"#]
        case "attach-surface":
            let snapshot = Data("daemon-snapshot".utf8).base64EncodedString()
            return [
                #"{"event":"vt-state","surface":1,"data":"\#(snapshot)"}"#,
                #"{"id":"\#(id)","ok":true,"data":{"lease":"lease-1"}}"#,
            ]
        default:
            return [#"{"id":"\#(id)","ok":true,"data":{}}"#]
        }
    }
}

final class ScriptedDaemonCarrier: CmuxTUICarrier {
    let events: AsyncStream<SSHSessionEvent>
    private let continuation: AsyncStream<SSHSessionEvent>.Continuation
    private let daemon: ScriptedDaemon
    private let pending = LaneTestLocked(Data())

    init(daemon: ScriptedDaemon) {
        self.daemon = daemon
        (events, continuation) = AsyncStream<SSHSessionEvent>.makeStream()
    }

    func write(_ data: Data) async throws {
        let lines: [Data] = pending.withLock { buffer in
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        for line in lines {
            guard let request = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            daemon.record(request)
            for reply in daemon.replies(to: request) {
                continuation.yield(.stdout(Data((reply + "\n").utf8)))
            }
        }
    }

    func close() async {
        continuation.yield(.closed)
        continuation.finish()
    }
}

/// A lock-guarded value (Mutex needs macOS 15; the package targets 14).
final class LaneTestLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
