import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `file.open` from the page: the path comes from reply text and tool calls, so the host opens a
/// file only under one of the pane's roots (after symlinks and `..` are resolved), and only on a
/// real user gesture in the pane. Same rule as the relay's `transport.path_outside_roots`.
@MainActor
@Suite struct AgentPaneFileOpenRootsTests {
    /// A project root with one source file, and a sibling folder outside it.
    private struct Fixture {
        let base: URL
        let root: URL
        let inside: URL
        let outside: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("file-open-roots-\(UUID().uuidString)")
            root = base.appendingPathComponent("project", isDirectory: true)
            let other = base.appendingPathComponent("secrets", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            inside = root.appendingPathComponent("Retry.swift")
            outside = other.appendingPathComponent("id_rsa.txt")
            try Data("x".utf8).write(to: inside)
            try Data("key".utf8).write(to: outside)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    private static func model(roots: [String]) -> (AgentPaneModel, () -> [String]) {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.workspaceRoots = { roots }
        var opened: [String] = []
        model.onOpenFile = { url, _ in
            opened.append(url.path)
            return true
        }
        return (model, { opened })
    }

    private static func code(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func aFileOutsideEveryRootNeverOpens() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (model, opened) = Self.model(roots: [fixture.root.path])
        model.transport.gestures.record()
        let reply = await model.respond(to: .openFile(path: fixture.outside.path, target: .editor))
        #expect(reply["ok"] as? Bool == false)
        #expect(Self.code(reply) == "transport.path_outside_roots")
        #expect(opened().isEmpty)
    }

    @Test func aPaneWithNoRootsOpensNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (model, opened) = Self.model(roots: [])
        model.transport.gestures.record()
        let reply = await model.respond(to: .openFile(path: fixture.inside.path, target: .editor))
        #expect(Self.code(reply) == "transport.path_outside_roots")
        #expect(opened().isEmpty)
    }

    /// A link inside the root that points out of it, and a `..` walk out of it, are outside.
    @Test func linksAndDotDotAreResolvedBeforeTheRootCheck() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outside)
        let (model, opened) = Self.model(roots: [fixture.root.path])
        model.transport.gestures.record()
        var reply = await model.respond(to: .openFile(path: link.path, target: .editor))
        #expect(Self.code(reply) == "transport.path_outside_roots")
        model.transport.gestures.record()
        reply = await model.respond(to: .openFile(path: fixture.root.path + "/../secrets/id_rsa.txt", target: .editor))
        #expect(Self.code(reply) == "transport.path_outside_roots")
        #expect(opened().isEmpty)
    }

    /// A root that is itself spelled through a link (the temporary folder is `/var` -> `/private/var`)
    /// still contains its files; the app gets the canonical path.
    @Test func aFileUnderARootOpensWithAGesture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (model, opened) = Self.model(roots: [fixture.root.path])
        model.transport.gestures.record()
        let reply = await model.respond(to: .openFile(path: fixture.inside.path, target: .editor))
        #expect(reply["ok"] as? Bool == true)
        let canonical = try #require(AcpmuxPathPolicy.canonical(fixture.inside.path))
        #expect(opened() == [canonical])
    }

    /// No gesture (page script alone, or reply text that calls the op on render) opens nothing,
    /// and one gesture opens one file.
    @Test func everyOpenSpendsOneGesture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (model, opened) = Self.model(roots: [fixture.root.path])
        var reply = await model.respond(to: .openFile(path: fixture.inside.path, target: .editor))
        #expect(Self.code(reply) == "transport.gesture_required")
        model.transport.gestures.record()
        reply = await model.respond(to: .openFile(path: fixture.inside.path, target: .editor))
        #expect(reply["ok"] as? Bool == true)
        reply = await model.respond(to: .openFile(path: fixture.inside.path, target: .editor))
        #expect(Self.code(reply) == "transport.gesture_required")
        #expect(opened().count == 1)
    }

    /// A folder the user added to the pane (the add-folder sheet) is a root for files too.
    @Test func aFolderTheUserAddedIsARoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (model, opened) = Self.model(roots: [fixture.root.path])
        model.transport.addedRoots.append(fixture.outside.deletingLastPathComponent().path)
        model.transport.gestures.record()
        let reply = await model.respond(to: .openFile(path: fixture.outside.path, target: .editor))
        #expect(reply["ok"] as? Bool == true)
        #expect(opened().count == 1)
    }
}
