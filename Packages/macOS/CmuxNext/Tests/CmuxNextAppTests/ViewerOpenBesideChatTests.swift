import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemonService
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

/// A viewer a person opens on a lone agent chat (Open Diff Viewer's shortcut, the palette or the File menu, Open Markdown
/// File, Open File) lands on the chat's right, as the chat header's Changes does, never as a tab beside the chat in its
/// pane (Leo, 2026-11-04: "the diff viewer indeed opens a tab... but it should go along with the right side split logic
/// instead of simply opening on the left/main pane").
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct ViewerOpenBesideChatTests {
    enum Open: String, CaseIterable {
        case diff, markdown, file
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), arguments: Open.allCases)
    func aViewerOpenedOnALoneChatLandsRightOfTheChat(_ open: Open) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "viewer-beside-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.git(root.path, "init", "-q")
        let note = root.appending(path: "NOTES.md"), text = root.appending(path: "notes.txt")
        try "# Notes\n".write(to: note, atomically: true, encoding: .utf8)
        try "notes\n".write(to: text, atomically: true, encoding: .utf8)
        // A repository with a commit and an unstaged change: the diff has a HEAD to compare with.
        try Self.git(root.path, "add", ".")
        try Self.git(root.path, "-c", "user.name=cmux", "-c", "user.email=cmux@example.com", "commit", "-q", "-m", "notes")
        try "notes, edited\n".write(to: text, atomically: true, encoding: .utf8)
        try await PasswordManagerRouteTests.withApp { services, connection in
            let store = services.daemon.store
            let source = try #require(services.windows.active?.focusedPane)
            let content = try #require(source.workspace)
            let terminals = source.pane.tabs.map(\.surface)
            let chatReply = try await connection.request(NewConversationTabRequest(
                agentSession: AgentSessionRef(host: "install:test", session: "chat", harness: "codex"), pane: source.pane.handle))
            try await PasswordManagerRouteTests.until({ store.tab(surface: chatReply.surface) != nil })
            for terminal in terminals { try await connection.closeTab(terminal) }
            try await PasswordManagerRouteTests.until({ source.pane.tabs.count == 1 })
            let chat = try #require(store.tab(surface: chatReply.surface))
            PaneHandlers.focus(source.layoutPaneID, in: content)
            try await PasswordManagerRouteTests.until({ content.focusedPane === source && source.selectedTab?.id == chat.id })
            // No beside flags: what the shortcut, the palette and the File menu run on the focused chat.
            let (id, path, page): (ActionID, URL, String) = switch open {
            case .diff: ("openDiffViewer", root, "diff")
            case .markdown: ("openMarkdownFile", note, "markdown")
            case .file: ("file.open", text, "editor")
            }
            let invocation = ActionInvocation(arguments: ["path": .string(path.path)], origin: .user)
            #expect(services.registry.perform(id, invocation: invocation))
            let opened = { store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.page == page } }
            let chatPane = { services.locateTab(chat.id, onMachine: services.daemon.machineID)?.1 }
            try await PasswordManagerRouteTests.until({
                guard let tab = opened(), let viewer = services.locateTab(model: tab)?.1, let home = chatPane() else { return false }
                return viewer !== home
            }, report: {
                let tab = opened()
                return "\(page) tab \(String(describing: tab?.id)) in \(String(describing: tab.flatMap { services.locateTab(model: $0)?.1.id })), chat in \(String(describing: chatPane()?.id))"
            })
            // The chat's own pane never lists the viewer.
            let home = try #require(chatPane())
            #expect(!home.tabs.contains { $0.page == page })
        }
    }

    private static func git(_ directory: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        try process.run()
        process.waitUntilExit()
    }
}
