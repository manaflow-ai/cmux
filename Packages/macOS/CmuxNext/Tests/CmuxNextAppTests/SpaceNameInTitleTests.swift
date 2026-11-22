import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Spaces stay out of sight until a second one (Lawrence 2026-11-20: "hide spaces by default"; a1315: "no space
/// name in the window title" with one space). The window list title (Window menu, Mission Control, Cmd-`) read
/// "Space 1 — workspace" for a person who never made a space; it names the space from the second space on.
@MainActor @Suite(.serialized)
struct SpaceNameInTitleTests {
    private func tree(spaces count: Int) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1", screens: []),
        ])
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: (0..<count).map { ProfileSnapshot(id: ProfileID(rawValue: "space-\($0)"), name: "Space \($0 + 1)", index: $0) },
            pins: [WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), profile: ProfileID(rawValue: "space-0"))],
            workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0)])
        return tree
    }

    private func title(of window: NSWindow?, until done: (String) -> Bool) async -> String {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(window?.title ?? ""), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return window?.title ?? ""
    }

    @Test func oneSpaceLeavesItsNameOutOfTheWindowTitle() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(spaces: 1))
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["k1"], frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        #expect(controller.state.profileID == ProfileID(rawValue: "space-0"))
        // The first title can come before the window is in its space ("cmux — k1"): watch it settle, for a bounded
        // while, and it never names the lone space.
        _ = await title(of: controller.window) { $0.contains("k1") }
        var seen: Set<String> = []
        let watchEnd = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < watchEnd {
            seen.insert(controller.window?.title ?? "")
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!seen.contains { $0.contains("Space 1") }, "one space and the window title names it: \(seen.sorted())")
        #expect(seen.contains { $0.contains("k1") }, "the title never named the workspace: \(seen.sorted())")

        // The person makes a second space: the title names the space again.
        store.apply(snapshot: tree(spaces: 2))
        let two = await title(of: controller.window) { $0.hasPrefix("Space 1") }
        #expect(two.hasPrefix("Space 1"), "two spaces and the window title does not name the space: \(two)")
    }
}
