import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// u18462 (Oct 30), on HTML and SVG opening as webpages: "no matter what opens them need
/// cli/mcp/cmd shift p for opening in editor tho, like think of the various different use cases".
/// Every open reaches the source and back through one action path, so the CLI, MCP, the palette
/// and the tab menu behave the same:
/// - `file.open` with `asText` (`cmux open --as-text`, `cmux file open --as-text`, MCP
///   `app_file_open`): an agent's or a script's open of HTML, SVG or Markdown shows its source.
/// - Edit Source (`browser.editSource`) on a rendered tab: an HTML page in a browser tab or a
///   Markdown page opens its source in the code editor.
/// - Open as Page (`file.openAsPage`) on a code editor tab: the file opens rendered again.
/// The tab menu shows each only on a tab it applies to.
@MainActor @Suite(.serialized, .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct FileSourceSwitchTests {
    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cn-source-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    private static func write(_ name: String, in folder: URL, _ text: String) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func pane(_ services: AppServices) throws -> PaneController {
        try #require(services.windows.active?.focusedPane)
    }

    /// The strip tab whose page `pages` shows `file`, in any pane of the active window.
    private static func pageTab(showing file: URL, in pages: FilePageService, _ services: AppServices) -> String? {
        guard let key = pages.debugTabs.first(where: { $0.file?.resolvingSymlinksInPath().path == file.path })?.key else { return nil }
        let panes = services.windows.controllers.flatMap { $0.content?.panes.values.map { $0 } ?? [] }
        return panes.lazy.flatMap(\.stripModel.tabs).map(\.id.rawValue).first { FilePageHandlers.providerKey($0, services) == key }
    }

    /// A daemon browser tab showing `file`, in any workspace.
    private static func browserTab(showing file: URL, _ services: AppServices) -> TabModel? {
        services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first {
            guard let url = $0.url.flatMap(URL.init(string:)), url.isFileURL else { return false }
            return url.resolvingSymlinksInPath().path == file.path
        }
    }

    private static func hidden(_ id: ActionID, onTab tab: String, _ services: AppServices) -> Bool {
        services.registry.action(for: id)?.targetHidden?(ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .user)) ?? false
    }

    private static func run(_ id: ActionID, onTab tab: String, _ services: AppServices) -> Bool {
        services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .cli))
    }

    /// `cmux open --as-text` and MCP: an agent's `file.open` of HTML, SVG or Markdown with
    /// `asText` opens the code editor; without it the file still renders.
    @Test(arguments: ["report.html", "logo.svg", "NOTES.md"])
    func anAgentsOpenAsTextShowsTheSource(_ name: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let folder = try Self.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = try Self.write(name, in: folder, name.hasSuffix(".svg") ? "<svg xmlns=\"http://www.w3.org/2000/svg\"/>\n" : "<h1>hi</h1>\n")
            let pane = try Self.pane(services)
            #expect(services.registry.perform("file.open", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .pane, id: pane.paneKey),
                arguments: ["path": .string(file.path), "asText": .bool(true)], origin: .cli)))
            try await PasswordManagerRouteTests.until({ Self.pageTab(showing: file, in: services.viewers.editorPages, services) != nil },
                                                      report: { "\(name) did not open in the code editor" })
            #expect(Self.browserTab(showing: file, services) == nil, "\(name) rendered as well")
            #expect(Self.pageTab(showing: file, in: services.viewers.markdownPages, services) == nil, "\(name) rendered as well")
        }
    }

    /// An HTML page an agent opened renders in a browser tab; Edit Source there opens its source,
    /// and Open as Page on that code editor tab renders it again. The tab menu shows only the one
    /// that applies.
    @Test func editSourceAndOpenAsPageRoundTripAnHTMLPage() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let folder = try Self.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = try Self.write("index.html", in: folder, "<h1>round trip</h1>\n")
            let pane = try Self.pane(services)
            #expect(services.registry.perform("file.open", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .pane, id: pane.paneKey), arguments: ["path": .string(file.path)], origin: .cli)))
            try await PasswordManagerRouteTests.until({ Self.browserTab(showing: file, services) != nil }, report: { "the page did not render" })
            let page = try #require(Self.browserTab(showing: file, services)).id
            #expect(!Self.hidden("browser.editSource", onTab: page, services), "the rendered page's menu has no Edit Source")
            #expect(Self.hidden("file.openAsPage", onTab: page, services), "the rendered page's menu offers Open as Page")

            #expect(Self.run("browser.editSource", onTab: page, services))
            try await PasswordManagerRouteTests.until({ Self.pageTab(showing: file, in: services.viewers.editorPages, services) != nil },
                                                      report: { "Edit Source opened no code editor" })
            let source = try #require(Self.pageTab(showing: file, in: services.viewers.editorPages, services))
            #expect(!Self.hidden("file.openAsPage", onTab: source, services), "the source tab's menu has no Open as Page")
            #expect(Self.hidden("browser.editSource", onTab: source, services), "the source tab's menu offers Edit Source")

            // Back to the page: the browser tab showing it again (selected where it is, or a new one).
            let before = services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).count
            #expect(Self.run("file.openAsPage", onTab: source, services))
            try await PasswordManagerRouteTests.until({
                services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).count > before
            }, report: { "Open as Page opened no page" })
            #expect(Self.browserTab(showing: file, services) != nil)
        }
    }

    /// Markdown: Edit Source on the markdown page opens the code editor, Open as Page there opens the
    /// markdown page.
    @Test func editSourceAndOpenAsPageRoundTripMarkdown() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let folder = try Self.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = try Self.write("README.md", in: folder, "# Round trip\n")
            let pane = try Self.pane(services)
            #expect(services.registry.perform("file.open", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .pane, id: pane.paneKey), arguments: ["path": .string(file.path)], origin: .cli)))
            try await PasswordManagerRouteTests.until({ Self.pageTab(showing: file, in: services.viewers.markdownPages, services) != nil },
                                                      report: { "the markdown page did not open" })
            let rendered = try #require(Self.pageTab(showing: file, in: services.viewers.markdownPages, services))
            #expect(!Self.hidden("browser.editSource", onTab: rendered, services), "the markdown page's menu has no Edit Source")

            #expect(Self.run("browser.editSource", onTab: rendered, services))
            try await PasswordManagerRouteTests.until({ Self.pageTab(showing: file, in: services.viewers.editorPages, services) != nil },
                                                      report: { "Edit Source on Markdown opened no code editor" })
            let source = try #require(Self.pageTab(showing: file, in: services.viewers.editorPages, services))
            #expect(!Self.hidden("file.openAsPage", onTab: source, services))
            #expect(Self.run("file.openAsPage", onTab: source, services))
        }
    }

    /// A plain source file has neither row, and Open as Page on it opens nothing.
    @Test func aPlainSourceFileHasNeitherRow() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let folder = try Self.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = try Self.write("main.swift", in: folder, "print(1)\n")
            let pane = try Self.pane(services)
            #expect(services.registry.perform("file.open", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .pane, id: pane.paneKey), arguments: ["path": .string(file.path)], origin: .cli)))
            try await PasswordManagerRouteTests.until({ Self.pageTab(showing: file, in: services.viewers.editorPages, services) != nil },
                                                      report: { "the editor did not open" })
            let tab = try #require(Self.pageTab(showing: file, in: services.viewers.editorPages, services))
            #expect(Self.hidden("browser.editSource", onTab: tab, services))
            #expect(Self.hidden("file.openAsPage", onTab: tab, services))
            // A refused run opens nothing: no page renders the file.
            _ = Self.run("file.openAsPage", onTab: tab, services)
            #expect(Self.browserTab(showing: file, services) == nil)
            #expect(Self.pageTab(showing: file, in: services.viewers.markdownPages, services) == nil)
        }
    }
}
