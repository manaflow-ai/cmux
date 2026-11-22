import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// AGENT-CWD-FOR-FOLDERLESS-WORKSPACE, amendment (a): cmux-next has no explicit workspace delete,
/// and a History reopen gets a new workspace id. A close (window close, app quit, workspace close)
/// never deletes a workspace's agent-home folder, because chat files may be in it; a reopen from
/// History carries the folder over to the new id; the folder goes to the Trash (never a hard
/// delete) only when its History entry expires.
@MainActor
@Suite(.serialized) struct AgentHomeHistoryTests {
    final class Rig {
        let root: String
        let home: AgentHome
        let bin: String
        let history: AgentHomeHistory
        let tracker: ClosedWorkspaceTracker

        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-home-history-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            root = try #require(AgentHome.canonicalFolder(url.path))
            home = AgentHome(base: root + "/cmux/agent-home")
            let bin = root + "/Trash"
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            self.bin = bin
            // A stand-in Trash (the real one is the user's), run inline so the test sees it.
            history = AgentHomeHistory(home: home, trash: { url in
                try FileManager.default.moveItem(atPath: url.path, toPath: bin + "/" + url.lastPathComponent)
            }, run: { $0() })
            tracker = ClosedWorkspaceTracker(agentHomes: history)
        }

        /// The names in the stand-in Trash.
        var trashed: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: bin)) ?? []).sorted() }

        /// A folder with a chat file in it, as a chat leaves it.
        func folder(_ id: String) throws -> String {
            let path = try #require(home.ensure(id))
            try Data("notes".utf8).write(to: URL(fileURLWithPath: path + "/chat.md"))
            return path
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

        /// The machine shows `ids` (local workspaces, so each has an agent-home id).
        func show(_ ids: [String], generation: String = "g1") {
            var workspaces: [String: ClosedWorkspaceLog.Record] = [:]
            for id in ids {
                workspaces[id] = ClosedWorkspaceLog.Record(machine: "local", name: id, cwd: nil, tabCount: 1, closedAt: Date(),
                                                           agentHomeID: id)
            }
            tracker.apply(ClosedWorkspaceLog.Snapshot(machines: ["local": .init(generation: generation, workspaces: workspaces)]))
        }
    }

    @Test func aCloseKeepsTheFolder() throws {
        let rig = try Rig()
        let path = try rig.folder("ws-a")
        rig.show(["ws-a", "ws-b"])
        rig.show(["ws-b"])
        #expect(rig.tracker.records.map(\.agentHomeID) == ["ws-a"])
        #expect(rig.exists(path + "/chat.md"))
        #expect(rig.trashed.isEmpty)
        // The machine drops (an app quit or a daemon restart): nothing is recorded or removed.
        rig.tracker.apply(ClosedWorkspaceLog.Snapshot(machines: [:]))
        #expect(rig.exists(path + "/chat.md"))
    }

    @Test func aHistoryReopenMovesTheFolderToTheNewId() throws {
        let rig = try Rig()
        let path = try rig.folder("ws-old")
        rig.show(["ws-old"])
        rig.show([])
        let record = try #require(rig.tracker.records.first)
        let taken = try #require(rig.tracker.take(record.id))
        #expect(rig.history.reopened(from: taken.agentHomeID, to: "ws-new"))
        #expect(!rig.exists(path))
        #expect(rig.exists(rig.home.base + "/ws-new/chat.md"))
        #expect(rig.trashed.isEmpty)
        // A target that exists is never overwritten; a missing source is a no-op.
        _ = try rig.folder("ws-taken")
        _ = try rig.folder("ws-other")
        #expect(!rig.history.reopened(from: "ws-other", to: "ws-taken"))
        #expect(rig.exists(rig.home.base + "/ws-other/chat.md"))
        #expect(!rig.history.reopened(from: "ws-missing", to: "ws-fresh"))
        #expect(!rig.history.reopened(from: "../ws-other", to: "ws-fresh"))
    }

    @Test func anExpiredEntryTrashesItsFolder() throws {
        let rig = try Rig()
        let first = try rig.folder("ws-0")
        // capacity + 1 closes: the oldest entry expires.
        let ids = (0...ClosedWorkspaceLog.capacity).map { "ws-\($0)" }
        for id in ids { rig.show([id]) }
        rig.show([])
        #expect(rig.tracker.records.count == ClosedWorkspaceLog.capacity)
        #expect(rig.trashed == ["ws-0"])
        #expect(!rig.exists(first))
        // Removing an entry from History, or clearing History, expires it too.
        let second = try rig.folder("ws-1")
        let entry = try #require(rig.tracker.records.first { $0.agentHomeID == "ws-1" })
        rig.tracker.discard(entry.id)
        #expect(!rig.exists(second))
        let third = try rig.folder("ws-2")
        rig.tracker.clear(since: nil)
        #expect(!rig.exists(third))
        #expect(rig.tracker.records.isEmpty)
    }

    @Test func aSymlinkAtTheFolderPathIsNeverMovedOrTrashed() throws {
        let rig = try Rig()
        let outside = rig.root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: outside + "/keep.md"))
        _ = try rig.folder("seed")
        try FileManager.default.createSymbolicLink(atPath: rig.home.base + "/ws-link", withDestinationPath: outside)
        #expect(!rig.history.reopened(from: "ws-link", to: "ws-new"))
        rig.history.expired(["ws-link"])
        #expect(rig.trashed.isEmpty)
        #expect(rig.exists(outside + "/keep.md"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: rig.home.base + "/ws-link")) == outside)
    }
}
