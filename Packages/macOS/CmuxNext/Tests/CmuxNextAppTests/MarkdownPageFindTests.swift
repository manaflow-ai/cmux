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
@MainActor @Suite(.serialized, .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct MarkdownPageFindTests {
    @Test func findAndItsNeighborsReachTheMarkdownPage() async throws {
        // The test bundle has no built webviews-app: a scratch root serves the page's document, so
        // the tab gets its real page view (the first registration per process wins).
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-mdfind-root-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["index.html", PageDescriptor.markdownEntry] {
            try Data("<html><body></body></html>".utf8).write(to: root.appendingPathComponent(name))
        }
        PageID.registerBundledRoot(root, for: PageDescriptor.markdown.id)
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
            @MainActor func tab() -> (key: String, file: URL?, page: PageWebView?)? {
                pages.debugTabs.first { $0.file?.resolvingSymlinksInPath().path == file.path }
            }
            // The strip tab that shows the file, in whichever pane `file.open` put it.
            @MainActor func shown() -> (pane: PaneController, id: String)? {
                guard let key = tab()?.key else { return nil }
                for controller in services.windows.controllers {
                    for candidate in controller.content?.panes.values.map({ $0 }) ?? [] {
                        if let id = candidate.stripModel.tabs.map(\.id.rawValue).first(where: { FilePageHandlers.providerKey($0, services) == key }) {
                            return (candidate, id)
                        }
                    }
                }
                return nil
            }
            try await PasswordManagerRouteTests.until({ shown() != nil }, report: { "the markdown tab did not open" })
            let (host, tabID) = try #require(shown())
            // A headless test window never draws the tab: the pane shows it here, as on screen,
            // which makes its page view.
            if host.stripModel.selectedID?.rawValue != tabID, let strip = host.stripModel.tabs.first(where: { $0.id.rawValue == tabID }) {
                host.select(strip.id)
            }
            if host.currentContent == nil { host.showSelected() }
            let router = try #require(tab()?.page, "the markdown tab has no page view").router

            // Stand in for the page's script: subscribe to its command stream and record what arrives.
            var commands: [String] = []
            router.sendWithDrop = nil
            router.send = { envelope in
                if let command = envelope["data"]?["command"]?.stringValue { commands.append(command) }
            }
            let reply = await router.handle(["t": "sub", "id": 9001, "stream": .string(PageNativeOp.pageCommand)])
            #expect(reply["t"]?.stringValue == "ok")

            let target = ActionTargetRef(kind: .tab, id: tabID)
            for action in ["find", "findNext", "findPrevious", "useSelectionForFind", "hideFind"] {
                _ = services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(target: target, origin: .cli))
            }
            #expect(commands.filter { $0 != PageNativeOp.focusContent }
                == ["find", "findNext", "findPrevious", "useSelectionForFind", "hideFind"])
        }
    }
}
