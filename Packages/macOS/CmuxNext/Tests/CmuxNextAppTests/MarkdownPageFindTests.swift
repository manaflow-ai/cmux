import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextPages
import Foundation
import Testing

/// User, Oct 31: "cmd f doesnt work in markdown". Find (Cmd-F, Edit > Find, the palette, `cmux
/// terminal find`) and its neighbors reached the code editor page but refused a Markdown page as
/// "not a terminal", so Cmd-F in a Markdown tab did nothing. They now reach the Markdown page as its
/// page commands, the same path the code editor takes, and the page draws its find pill.
@MainActor @Suite(.serialized)
struct MarkdownPageFindTests {
    @Test func findAndItsNeighborsReachTheMarkdownPage() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cn-mdfind-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.resolvingSymlinksInPath().appendingPathComponent("NOTES.md")
            try "# Notes\n\nfind me, then find me again\n".write(to: file, atomically: true, encoding: .utf8)
            let pane = try #require(services.windows.active?.focusedPane)
            #expect(services.registry.perform("file.open", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .pane, id: pane.paneKey), arguments: ["path": .string(file.path)], origin: .cli)))
            let pages = services.viewers.markdownPages
            func page() -> PageWebView? {
                pages.debugTabs.first { $0.file?.resolvingSymlinksInPath().path == file.path }?.page
            }
            try await PasswordManagerRouteTests.until({ page() != nil }, report: { "the markdown page did not open" })
            let router = try #require(page()).router

            // Stand in for the page's script: subscribe to its command stream and record what arrives.
            var commands: [String] = []
            router.send = { envelope in
                if let command = envelope["data"]?["command"]?.stringValue { commands.append(command) }
            }
            let reply = await router.handle(["t": "sub", "id": 9001, "stream": .string(PageNativeOp.pageCommand)])
            #expect(reply["t"]?.stringValue == "ok")

            let target = ActionTargetRef(kind: .pane, id: pane.paneKey)
            for action in ["find", "findNext", "findPrevious", "useSelectionForFind", "hideFind"] {
                _ = services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(target: target, origin: .cli))
            }
            #expect(commands.filter { $0 != PageNativeOp.focusContent }
                == ["find", "findNext", "findPrevious", "useSelectionForFind", "hideFind"])
        }
    }
}
