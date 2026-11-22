import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new chat's first Send in Cloud (`cloud.startChat`) and the person's gesture: it needs none, like any Send
/// (#45429), except where the gesture is the person's pick of what leaves this Mac.
@Suite
@MainActor
struct AgentPaneCloudStartGestureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class Starts { var seen: [AgentPaneCloudStart] = [] }

    private static func pane(_ starts: Starts, root: String? = nil) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost())
        if let root { model.transport.roots = { [root] } }
        model.onCloudStartChat = { start in
            starts.seen.append(start)
            return AgentPaneReply.success(["machine": "cloud-1"])
        }
        return model
    }

    private static func start(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "cloud.startChat", "params": params])
    }

    /// A real folder (the check reads the disk) under its own new root: (root, folder).
    private static func project() throws -> (root: String, folder: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-start-gesture-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("paint")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root.path, folder.path)
    }

    private static func canonical(_ path: String) -> String? { AcpmuxPathPolicy.canonical(path) }

    private static func code(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }

    private static let good: [String: Any] = ["task": "fix the build", "cwd": "/Users/me/src/paint", "harness": "codex", "model": "gpt-6-astra",
                                              "key": UUID().uuidString]

    /// A new chat's first Send in Cloud is a Send, and a Send needs no key press or click (#45429). The staging GUI
    /// probe's Enter (posted input, no person's gesture) came back "Click the choice again to apply it."
    /// (`transport.gesture_required`) on every Cloud reply, 2026-11-20. With no folder, or the tab's own, it starts.
    @Test func aNewChatsSendWithNoGestureStartsInCloudWithNoFolderOrTheTabsOwn() async throws {
        let starts = Starts()
        var noFolder = Self.good
        noFolder["cwd"] = nil
        let reply = await Self.pane(starts).respond(to: Self.start(noFolder))
        #expect(reply["ok"] as? Bool == true)
        let (root, folder) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let inRoot = await Self.pane(starts, root: root).respond(to: Self.start(Self.good.merging(["cwd": folder, "key": UUID().uuidString]) { $1 }))
        #expect(inRoot["ok"] as? Bool == true)
        #expect(starts.seen.map(\.task) == ["fix the build", "fix the build"])
        #expect(starts.seen.last?.cwd == Self.canonical(folder))
    }

    /// The gesture stays where it is the person's pick of what leaves this Mac: a folder under none of the tab's
    /// roots, and a prompt an automation seeded, which waits for the person's own Send.
    @Test func aSendWithNoGestureStillPicksNoOutsideFolderAndSendsNoSeededPrompt() async throws {
        let starts = Starts()
        let (root, folder) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (otherRoot, _) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: otherRoot) }
        let outside = await Self.pane(starts, root: otherRoot).respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))
        #expect(Self.code(outside) == "transport.gesture_required")
        // A root that is home or above it is no root (a terminal at `~` lists `~`): the folder is still a pick.
        let homeRooted = Self.pane(starts, root: root)
        homeRooted.transport.homeFolder = root
        #expect(Self.code(await homeRooted.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))) == "transport.gesture_required")
        // A tab rooted inside a Git working copy copies the whole copy, which is above its root: still a pick.
        try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent(".git"), withIntermediateDirectories: true)
        let narrow = Self.pane(starts, root: folder)
        #expect(Self.code(await narrow.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))) == "transport.gesture_required")
        var noFolder = Self.good
        noFolder["cwd"] = nil
        let seeded = Self.pane(starts)
        seeded.transport.gestures.holdAutomationSeed()
        #expect(Self.code(await seeded.respond(to: Self.start(noFolder))) == "transport.gesture_required")
        #expect(starts.seen.isEmpty)
        // The person's own Send still goes, and spends the gesture.
        seeded.transport.gestures.record()
        #expect(await seeded.respond(to: Self.start(noFolder.merging(["key": UUID().uuidString]) { $1 }))["ok"] as? Bool == true)
        #expect(!seeded.transport.gestures.isAvailable)
    }
}
