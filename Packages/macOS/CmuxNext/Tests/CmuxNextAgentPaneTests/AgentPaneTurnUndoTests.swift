import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `turn.undo` from the edited-files card: the host writes a file back to the turn's first
/// content only while the file still holds exactly the turn's last content, never through git
/// and never through the agent. Each test runs in its own temporary folder, the pane's only root.
@MainActor
@Suite struct AgentPaneTurnUndoTests {
    private struct Folder {
        let root: URL
        init() throws {
            let base = FileManager.default.temporaryDirectory.appending(path: "turn-undo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // The canonical path (/private/var/... on macOS), as the policy compares it.
            root = URL(fileURLWithPath: AcpmuxPathPolicy.canonical(base.path) ?? base.path)
        }
        func file(_ name: String, _ text: String? = nil) throws -> String {
            let url = root.appending(path: name)
            if let text { try Data(text.utf8).write(to: url) }
            return url.path
        }
        func text(_ name: String) -> String? {
            (try? Data(contentsOf: root.appending(path: name))).map { String(decoding: $0, as: UTF8.self) }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func model(roots: [String], gesture: Bool, trashed: TrashLog = TrashLog()) -> AgentPaneModel {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.workspaceRoots = { roots }
        model.trashFile = { url in
            trashed.urls.append(url)
            try FileManager.default.removeItem(at: url)
        }
        if gesture { model.transport.gestures.record() }
        return model
    }

    final class TrashLog: @unchecked Sendable { var urls: [URL] = [] }

    private static func undo(_ model: AgentPaneModel, _ files: [[String: Any]], apply: Bool = true) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "turn.undo", "params": ["files": files, "apply": apply]] as [String: Any]))
    }

    /// The statuses by path, or the error code.
    private static func statuses(_ reply: [String: Any]) -> [String: String] {
        guard reply["ok"] as? Bool == true else {
            return ["error": ((reply["error"] as? [String: Any])?["code"] as? String) ?? "?"]
        }
        let files = (reply["value"] as? [String: Any])?["files"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: files.map { ($0["path"] as? String ?? "", $0["status"] as? String ?? "") })
    }

    @Test func aFileThatStillHoldsTheTurnsBytesGoesBackToItsFirstContent() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let path = try folder.file("a.txt", "after\n")
        let model = Self.model(roots: [folder.root.path], gesture: true)
        let reply = await Self.undo(model, [["path": path, "before": "before\n", "after": "after\n"]])
        #expect(Self.statuses(reply) == [path: "reverted"])
        #expect(folder.text("a.txt") == "before\n")
    }

    @Test func aFileChangedSinceTheTurnIsRefusedAndKeepsItsBytes() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let changed = try folder.file("changed.txt", "after\nuser edit\n")
        let same = try folder.file("same.txt", "after\n")
        let model = Self.model(roots: [folder.root.path], gesture: true)
        let reply = await Self.undo(model, [
            ["path": changed, "before": "before\n", "after": "after\n"],
            ["path": same, "before": "before\n", "after": "after\n"],
        ])
        #expect(Self.statuses(reply) == [changed: "changed", same: "reverted"])
        #expect(folder.text("changed.txt") == "after\nuser edit\n")
        #expect(folder.text("same.txt") == "before\n")
    }

    @Test func aDryRunSaysWhatWouldHappenAndWritesNothing() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let path = try folder.file("a.txt", "after\n")
        let created = try folder.file("new.txt", "made\n")
        let model = Self.model(roots: [folder.root.path], gesture: true)
        let reply = await Self.undo(model, [
            ["path": path, "before": "before\n", "after": "after\n"],
            ["path": created, "before": NSNull(), "after": "made\n"],
        ], apply: false)
        #expect(Self.statuses(reply) == [path: "wouldRevert", created: "wouldTrash"])
        #expect(folder.text("a.txt") == "after\n")
        #expect(folder.text("new.txt") == "made\n")
    }

    /// A file the turn created goes to the Trash, never a plain delete.
    @Test func aFileTheTurnCreatedGoesToTheTrash() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let path = try folder.file("new.txt", "made\n")
        let trashed = TrashLog()
        let model = Self.model(roots: [folder.root.path], gesture: true, trashed: trashed)
        let reply = await Self.undo(model, [["path": path, "before": NSNull(), "after": "made\n"]])
        #expect(Self.statuses(reply) == [path: "trashed"])
        #expect(trashed.urls.map(\.path) == [path])
    }

    @Test func aSymlinkIsNeverFollowedOrWritten() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let target = try folder.file("target.txt", "after\n")
        let link = folder.root.appending(path: "link.txt").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let model = Self.model(roots: [folder.root.path], gesture: true)
        let reply = await Self.undo(model, [["path": link, "before": "before\n", "after": "after\n"]])
        #expect(Self.statuses(reply) == [link: "cannotUndo"])
        #expect(folder.text("target.txt") == "after\n")
    }

    @Test func aPathOutsideThePanesRootsIsRefused() async throws {
        let folder = try Folder()
        let other = try Folder()
        defer { folder.remove(); other.remove() }
        let outside = try other.file("a.txt", "after\n")
        let model = Self.model(roots: [folder.root.path], gesture: true)
        let reply = await Self.undo(model, [["path": outside, "before": "before\n", "after": "after\n"]])
        #expect(Self.statuses(reply) == [outside: "outsideRoots"])
        #expect(other.text("a.txt") == "after\n")
    }

    @Test func withoutAUserGestureNothingIsReadOrWritten() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let path = try folder.file("a.txt", "after\n")
        let model = Self.model(roots: [folder.root.path], gesture: false)
        let reply = await Self.undo(model, [["path": path, "before": "before\n", "after": "after\n"]])
        #expect(Self.statuses(reply) == ["error": AgentPaneTransportError.gestureRequired.rawValue])
        #expect(folder.text("a.txt") == "after\n")
    }

    /// One gesture covers one request: the dry run spends it, so the apply needs the confirm click.
    @Test func eachRequestSpendsItsOwnGesture() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let path = try folder.file("a.txt", "after\n")
        let model = Self.model(roots: [folder.root.path], gesture: true)
        let file: [String: Any] = ["path": path, "before": "before\n", "after": "after\n"]
        #expect(Self.statuses(await Self.undo(model, [file], apply: false)) == [path: "wouldRevert"])
        #expect(Self.statuses(await Self.undo(model, [file])) == ["error": AgentPaneTransportError.gestureRequired.rawValue])
        model.transport.gestures.record()
        #expect(Self.statuses(await Self.undo(model, [file])) == [path: "reverted"])
    }

    /// A file without its full text (an edit fragment) never reaches the host: the request is
    /// refused whole, so a malformed list cannot write half of itself.
    @Test func aRequestWithoutFullTextsIsInvalid() {
        let bad: [[String: Any]] = [
            ["path": "/repo/a.txt", "before": "x"],
            ["path": "/repo/a.txt", "after": "y"],
            ["path": "relative.txt", "before": "x", "after": "y"],
            ["path": "/repo/a.txt", "before": 3, "after": "y"],
            ["path": "/repo/a.txt", "before": "x", "after": "y", "mode": "0777"],
        ]
        for file in bad {
            let request = AgentPaneRequest(body: ["method": "turn.undo", "params": ["files": [file], "apply": true]] as [String: Any])
            #expect(request == .invalidTurnUndo, "\(file)")
        }
        let extra = AgentPaneRequest(body: ["method": "turn.undo", "params": ["files": [], "apply": true, "cwd": "/"]] as [String: Any])
        #expect(extra == .invalidTurnUndo)
    }
}
