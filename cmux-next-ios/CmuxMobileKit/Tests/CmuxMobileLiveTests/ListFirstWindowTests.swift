import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The setup batch asks a Mac that advertised `list-workspaces-page-v1` for its first window
/// only, so the first Home/Workspaces content costs the same at 10, 100 and 1,000 workspaces,
/// and the whole tree follows in the background. A Mac not yet seen to advertise it gets
/// today's batch.
@MainActor
@Suite struct ListFirstWindowTests {
    private func defaults() -> UserDefaults {
        let suite = "ListFirstWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func theSetupListIsTheFirstWindowAndTheWholeTreeFollows() async throws {
        let defaults = defaults()
        var setupBytes: [Int: Int] = [:]
        for count in [10, 100, 1_000] {
            // The first connect to a Mac: today's batch, whole tree; its identify is noted.
            let first = PagingDaemonChannel(workspaces: count, advertisesPages: true)
            let cold = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
            cold.firstWindowDefaults = defaults
            await cold.bind(first, macID: "mac-\(count)")
            #expect(first.limitsSent.first == .some(nil), "a Mac not yet seen got a limit")
            #expect(cold.tree?.workspaces.count == count)
            await cold.bind(nil, macID: "mac-\(count)")
            first.finish()

            // The next connect: the setup list is the first window, drawn first.
            let channel = PagingDaemonChannel(workspaces: count, advertisesPages: true)
            let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
            sync.firstWindowDefaults = defaults
            var drawn: [Int] = []
            sync.onTree = { drawn.append($0.workspaces.count) }
            await sync.bind(channel, macID: "mac-\(count)")
            #expect(channel.limitsSent.first == .some(ListFirstWindow.limit))
            #expect(drawn.first == min(count, ListFirstWindow.limit), "first content: \(drawn)")
            setupBytes[count] = channel.replyBytes.first ?? 0
            // The rest follows after first content, with no limit.
            let whole = try await sync.listNow()
            #expect(whole.workspaces.count == count)
            #expect(channel.limitsSent.dropFirst().allSatisfy { $0 == nil }, "\(channel.limitsSent)")
            await sync.bind(nil, macID: "mac-\(count)")
            channel.finish()
        }
        // The first window's bytes do not grow with the workspaces past the window.
        let at100 = try #require(setupBytes[100]), at1000 = try #require(setupBytes[1_000])
        #expect(at1000 == at100 + 1, "first window: \(setupBytes)")
        print("FIRST-WINDOW setup_list_bytes=\(setupBytes.sorted { $0.key < $1.key })")
    }

    /// A Mac whose identify does not advertise the window is never sent a limit, and one that
    /// stops advertising it is forgotten.
    @Test func aMacWithoutTheCapabilityGetsTodaysBatch() async throws {
        let defaults = defaults()
        ListFirstWindow.note("mac", honors: true, defaults: defaults)
        let old = PagingDaemonChannel(workspaces: 50, advertisesPages: false)
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        sync.firstWindowDefaults = defaults
        await sync.bind(old, macID: "mac")
        // Sent once (recorded last time), and forgotten from its identify.
        #expect(!ListFirstWindow.honors("mac", defaults: defaults))
        _ = try await sync.listNow()
        #expect(sync.tree?.workspaces.count == 50)
        await sync.bind(nil, macID: "mac")
        old.finish()

        let again = PagingDaemonChannel(workspaces: 50, advertisesPages: false)
        await sync.bind(again, macID: "mac")
        #expect(again.limitsSent.allSatisfy { $0 == nil }, "\(again.limitsSent)")
        await sync.bind(nil, macID: "mac")
        again.finish()
    }

    @Test func aPartialPageIsDrawnOverTheRowsAlreadyHeld() {
        #expect(ListFirstWindow.isPartial(Data(#"{"ok":true,"data":{"total":5,"workspaces":[{}]}}"#.utf8)))
        #expect(!ListFirstWindow.isPartial(Data(#"{"ok":true,"data":{"total":1,"workspaces":[{}]}}"#.utf8)))
        #expect(!ListFirstWindow.isPartial(Data(#"{"ok":true,"data":{"workspaces":[{}]}}"#.utf8)))
        #expect(ListFirstWindow.params(honors: false).isEmpty)
        #expect(ListFirstWindow.params(honors: true)["limit"] as? Int == ListFirstWindow.limit)
    }
}

/// A daemon behind its Mac lane that answers `limit` with the first rows and `total`, and
/// advertises `list-workspaces-page-v1` when asked to.
private final class PagingDaemonChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let advertisesPages: Bool
    private let rows: [String]
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false
    private var limits: [Int?] = []
    private var bytes: [Int] = []

    var limitsSent: [Int?] { lock.withLock { limits } }
    var replyBytes: [Int] { lock.withLock { bytes } }

    init(workspaces: Int, advertisesPages: Bool) {
        self.advertisesPages = advertisesPages
        rows = (0..<workspaces).map { index in
            #"{"id":\#(index + 1),"key":"ws\#(index)","name":"Workspace \#(index)","screens":[{"id":\#(index + 1),"active":true,"panes":[{"id":\#(index + 1),"tabs":[{"surface":\#(index + 1),"kind":"pty","title":"zsh","cwd":"/Users/leo/projects/repo","git_branch":"main"}]}]}]}"#
        }
    }

    func send(_ data: Data) async throws {
        for line in data.split(separator: 0x0A) {
            guard let request = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = request["id"] as? String else { continue }
            if request["operation"] != nil {
                push(id: id, body: #"{"ok":true,"result":{}}"#)
                continue
            }
            switch request["cmd"] as? String {
            case "identify":
                let capabilities = advertisesPages ? #"["list-workspaces-limit-v1","list-workspaces-page-v1"]"# : "[]"
                push(id: id, body: #"{"ok":true,"data":{"app":"cmux-tui","version":"test","protocol":12,"capabilities":\#(capabilities)}}"#)
            case "list-agents":
                push(id: id, body: #"{"ok":true,"data":{"agents":[]}}"#)
            case "list-workspaces":
                let limit = request["limit"] as? Int
                lock.withLock { limits.append(limit) }
                let identity = #""registry_id":"r","generation":"g","workspace_revision":1,"pane_revision":1,"terminal_revision":1"#
                let body: String
                if let limit {
                    let page = rows.prefix(limit).joined(separator: ",")
                    let next = limit < rows.count ? #","next":\#(limit)"# : ""
                    body = #"{"ok":true,"data":{\#(identity),"total":\#(rows.count)\#(next),"workspaces":[\#(page)]}}"#
                } else {
                    body = #"{"ok":true,"data":{\#(identity),"workspaces":[\#(rows.joined(separator: ","))]}}"#
                }
                push(id: id, body: body, counted: true)
            default:
                push(id: id, body: #"{"ok":true,"data":{}}"#)
            }
        }
    }

    func receive() async throws -> Data? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if !inbox.isEmpty { continuation.resume(returning: inbox.removeFirst()) }
                else if closed { continuation.resume(returning: nil) }
                else { waiter = continuation }
            }
        }
    }

    func close(code: String, reason: String) async { finish() }

    func finish() {
        lock.withLock {
            closed = true
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }

    private func push(id: String, body: String, counted: Bool = false) {
        let data = Data(("{\"id\":\"\(id)\"," + String(body.dropFirst()) + "\n").utf8)
        lock.withLock {
            guard !closed else { return }
            if counted { bytes.append(data.count) }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: data)
            } else {
                inbox.append(data)
            }
        }
    }
}
