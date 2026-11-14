import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The phone's workspace list sends what it holds as `known`
/// (`list-workspaces-known-v1`, hq#10926), so a list of a tree it already has
/// costs the daemon's small `unchanged` answer instead of the whole tree, and an
/// older daemon (whose Mac lane refuses a field it does not know) never gets it.
@MainActor
@Suite struct WorkspaceSyncKnownTests {
    /// The phone's lists at 1,000 workspaces: after the first whole tree with a
    /// revision, each list of the same tree is answered `unchanged` and keeps it.
    @Test func aListOfTheHeldTreeIsAnsweredUnchanged() async throws {
        let channel = KnownDaemonChannel(workspaces: 1_000, advertisesKnown: true)
        defer { channel.finish() }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        var published = 0
        sync.onTree = { _ in published += 1 }
        await sync.bind(channel, macID: "mac")
        let first = try await sync.listNow()
        #expect(first.workspaces.count == 1_000)
        let wholeLists = channel.wholeReplies
        let publishedBefore = published
        // The phone asked with `{}` before it held a revision, then with the revision it got.
        #expect(channel.knownSent.first?.isEmpty == true)

        let before = channel.listBytes
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<5 { _ = try await sync.listNow() }
        let elapsed = clock.now - started
        let bytes = channel.listBytes - before
        #expect(channel.wholeReplies == wholeLists, "a list of the held tree read the whole tree again")
        #expect(channel.unchangedReplies == 5)
        #expect(channel.knownSent.last?["tree_revision"] as? String == channel.treeRevision)
        #expect(bytes < 5 * 400, "unchanged answers took \(bytes) bytes")
        #expect(published == publishedBefore, "an unchanged answer republished the tree")
        #expect(sync.tree?.workspaces.count == 1_000)
        print("KNOWN-PHONE workspaces=1000 whole_reply_bytes=\(channel.wholeReplyBytes) "
              + "unchanged_reply_bytes=\(bytes / 5) five_unchanged_lists=\(elapsed)")

        // A change moves the revision: the next list is the whole tree again.
        channel.bumpRevision()
        _ = try await sync.listNow()
        #expect(channel.wholeReplies == wholeLists + 1)
        await sync.bind(nil, macID: "mac")
    }

    /// A daemon that does not advertise the capability gets no `known` (its Mac
    /// lane refuses a field it does not know), and every list is the whole tree.
    @Test func anOlderDaemonNeverGetsKnown() async throws {
        let channel = KnownDaemonChannel(workspaces: 3, advertisesKnown: false)
        defer { channel.finish() }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        await sync.bind(channel, macID: "mac")
        let lists = channel.wholeReplies
        _ = try await sync.listNow()
        _ = try await sync.listNow()
        #expect(channel.knownSent.isEmpty)
        #expect(channel.refusedKnown == 0)
        #expect(channel.wholeReplies >= lists + 2)
        #expect(sync.tree?.workspaces.count == 3)
        await sync.bind(nil, macID: "mac")
    }
}

/// A daemon behind its Mac lane: `list-workspaces` answers `unchanged` to a
/// current `known` when it advertises `list-workspaces-known-v1`, and refuses
/// `known` (as an older lane does) when it does not.
private final class KnownDaemonChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let advertisesKnown: Bool
    private let rows: String
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false
    private var revision = 1
    private var whole = 0
    private var unchanged = 0
    private var refused = 0
    private var bytes = 0
    private var lastWholeBytes = 0
    private var sentKnown: [[String: Any]] = []

    var treeRevision: String { lock.withLock { "boot.\(revision)" } }
    var wholeReplies: Int { lock.withLock { whole } }
    var unchangedReplies: Int { lock.withLock { unchanged } }
    var refusedKnown: Int { lock.withLock { refused } }
    var listBytes: Int { lock.withLock { bytes } }
    var wholeReplyBytes: Int { lock.withLock { lastWholeBytes } }
    var knownSent: [[String: Any]] { lock.withLock { sentKnown } }

    init(workspaces: Int, advertisesKnown: Bool) {
        self.advertisesKnown = advertisesKnown
        rows = (0..<workspaces).map { index in
            #"{"id":\#(index + 1),"key":"ws\#(index)","name":"Workspace \#(index)","screens":[{"id":\#(index + 1),"active":true,"panes":[{"id":\#(index + 1),"tabs":[{"surface":\#(index + 1),"kind":"pty","title":"zsh \#(index)","cwd":"/Users/leo/projects/repo-\#(index)","git_branch":"feature/branch-\#(index)"}]}]}]}"#
        }.joined(separator: ",")
    }

    func bumpRevision() { lock.withLock { revision += 1 } }

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
                let capabilities = advertisesKnown ? #"["list-workspaces-known-v1"]"# : "[]"
                push(id: id, body: #"{"ok":true,"data":{"app":"cmux-tui","version":"test","protocol":12,"capabilities":\#(capabilities)}}"#)
            case "list-agents":
                push(id: id, body: #"{"ok":true,"data":{"agents":[]}}"#)
            case "list-workspaces":
                push(id: id, body: list(known: request["known"]), counted: true)
            default:
                push(id: id, body: #"{"ok":true,"data":{}}"#)
            }
        }
    }

    private func list(known: Any?) -> String {
        lock.withLock {
            let identity = #""registry_id":"r","generation":"g","workspace_revision":\#(revision),"pane_revision":1,"terminal_revision":1"#
            guard let known else {
                whole += 1
                return #"{"ok":true,"data":{\#(identity),"workspaces":[\#(rows)]}}"#
            }
            guard advertisesKnown else {
                refused += 1
                return #"{"ok":false,"error":"list-workspaces does not take known from a phone","error_code":"forbidden"}"#
            }
            let held = known as? [String: Any] ?? [:]
            sentKnown.append(held)
            let current = "boot.\(revision)"
            if held["tree_revision"] as? String == current, held["registry_id"] as? String == "r",
               held["generation"] as? String == "g", held["workspace_revision"] as? Int == revision,
               held["pane_revision"] as? Int == 1, held["terminal_revision"] as? Int == 1 {
                unchanged += 1
                return #"{"ok":true,"data":{"unchanged":true,"workspaces":[],\#(identity),"tree_revision":"\#(current)"}}"#
            }
            whole += 1
            return #"{"ok":true,"data":{\#(identity),"tree_revision":"\#(current)","workspaces":[\#(rows)]}}"#
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
            if counted {
                bytes += data.count
                if !body.contains(#""unchanged":true"#) { lastWholeBytes = data.count }
            }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: data)
            } else {
                inbox.append(data)
            }
        }
    }
}
