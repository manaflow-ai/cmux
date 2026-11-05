import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemonService
import CmuxNextLayout
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import struct CmuxNextBrowser.TerminalLinkResolver
import enum CmuxNextBrowser.TerminalLinkTarget

/// File actions keep a Cloud path on its machine, including paths absent from this Mac.
@MainActor @Suite(.serialized)
struct CloudFileRoutingTests {
    struct Fixture {
        let services: AppServices
        let controller: WindowController
        let pane: PaneController
        let root: URL

        func close() {
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func fixture(localPane: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "cloud-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
        services.machines.add(machine)
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "Cloud terminal")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        let daemon = localPane ? services.daemon : machine.daemon
        daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: "cloud-files", name: "Cloud", screens: [screen])]))
        services.windows.registry.provisional["cloud-file-window"] = ["cloud-files"]
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "cloud-file-window"))
        services.windows.select("cloud-files", in: controller.state)
        controller.showWorkspace(requested: controller.state.workspaceID)
        let shown = try #require(controller.focusedPane)
        try #require(shown.daemon.isLocal == localPane)
        let context = AppActionContext(services: services)
        AgentHandlers.bind(into: services.registry, context: context)
        ViewerHandlers.bind(into: services.registry, context: context)
        FilePageHandlers.bind(into: services.registry, context: context)
        TabHandlers.bind(into: services.registry, context: context)
        services.linkOpener.placement = { .samePane }
        return Fixture(services: services, controller: controller, pane: shown, root: root)
    }

    @Test func terminalPathOnAnOfflineMachineStillOpensItsRemoteErrorPage() async throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let services = fixture.services
        let daemon = fixture.pane.daemon
        daemon.store.noteHandshake(DaemonIdentity(capabilities: ["fs-v1"], generation: "offline-file-link"))
        let terminal = try #require(fixture.pane.pane.tabs.first)
        let delegate = TerminalHostDelegate()
        delegate.services = services
        let path = "/home/cmux/\(UUID().uuidString)/notes.md"
        await delegate.openMachineLink(path, cwd: "/home/cmux", on: daemon,
            (option: false, other: false, tab: ActionTargetRef(kind: .tab, id: terminal.id)))
        let pages = services.viewers.markdownPages
        let key = try #require(pages.debugTabs.first { $0.file?.path == path }?.key,
                               "an offline path must show the remote page's machine-specific error")
        #expect(pages.location(key)?.machine === daemon)
        #expect(pages.localFile(key) == nil)
    }

    @Test(arguments: ["docs.rs/serde", "www.example.com", "localhost:3000/docs"])
    func offlineTerminalWebLinksKeepTheirBrowserFallback(_ text: String) async throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let services = fixture.services
        let terminal = try #require(fixture.pane.pane.tabs.first)
        let delegate = TerminalHostDelegate()
        delegate.services = services
        let router = LinkRouter.shared
        let previousOpen = router.openInCmux, previousRouting = router.routing
        defer { router.openInCmux = previousOpen; router.routing = previousRouting }
        var opened: [URL] = []
        router.routing = { .fallback }
        router.openInCmux = { url, _, _ in opened.append(url) }
        guard case .url(let expected)? = TerminalLinkResolver().resolve(text, cwd: nil, allowsLocalFiles: false) else {
            Issue.record("expected a supported web address")
            return
        }
        await delegate.openMachineLink(text, cwd: "/home/cmux/project", on: fixture.pane.daemon,
            (option: false, other: false, tab: ActionTargetRef(kind: .tab, id: terminal.id)))
        #expect(opened == [expected])
        #expect(services.viewers.editorPages.debugTabs.isEmpty)
        #expect(services.viewers.markdownPages.debugTabs.isEmpty)
    }

    @Test(arguments: ["file.open", "openMarkdownFile"])
    func explicitFileActionsOpenOnThePaneMachine(_ action: String) async throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let services = fixture.services
        let path = "/home/cmux/\(UUID().uuidString)/notes.md"
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: fixture.pane.paneKey),
                                          arguments: ["path": .string(path)], origin: .cli)
        var refusal: String?
        let work = services.registry.capturingWork {
            refusal = services.registry.reportingRefusal {
                #expect(services.registry.perform(ActionID(rawValue: action), invocation: invocation))
            }
        }
        #expect(refusal == nil)
        for task in work { #expect(await task.value == nil) }
        let keys = services.pages.tabIDs(in: fixture.pane.paneKey)
        let key = try #require(keys.first { services.viewers.markdownPages.file($0)?.path == path })
        // A local open can never expose the same path to Finder or an external app.
        #expect(FilePageHandlers.file(ofTab: key, services) == nil)
    }

    @Test(arguments: FilePageKind.allCases)
    func externalFileActionsOnlyReceiveLocalFiles(_ kind: FilePageKind) throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let service = FilePageHandlers.service(kind, fixture.services)
        let file = fixture.root.appending(path: "same-path.md")
        try Data("local copy".utf8).write(to: file)
        let local = service.open(file, in: fixture.pane, focus: false)
        #expect(FilePageHandlers.file(ofTab: local, fixture.services) == file.resolvingSymlinksInPath())
        let remote = service.open(file, in: fixture.pane, focus: false, on: fixture.pane.daemon)
        #expect(remote != local)
        #expect(service.file(remote)?.path == file.path)
        #expect(FilePageHandlers.file(ofTab: remote, fixture.services) == nil,
                "a remote file was offered to this Mac's external-open actions")
    }

    /// Cloud pages have no movable daemon surface, so both new and reused tabs must release
    /// the placement turn immediately; otherwise the next link waits for a move that never runs.
    @Test(arguments: [false, true], ["notes.md", "source.swift", "report.html", "logo.svg"])
    func cloudFilesShownInPlaceDoNotHoldFollowingOpens(_ localPane: Bool, _ name: String) throws {
        let fixture = try Self.fixture(localPane: localPane)
        defer { fixture.close() }
        let services = fixture.services
        let machine = try #require(services.machines.remoteDaemons.first)
        let file = URL(fileURLWithPath: "/home/cmux/\(UUID().uuidString)/\(name)")
        services.linkOpener.placement = { .newColumn }
        for _ in 0..<2 {
            let opened = services.linkOpener.openFile(file, on: machine, from: fixture.pane)
            #expect(opened)
            #expect(!services.linkOpener.turns.isBusy(beside: fixture.pane.layoutPaneID),
                    "a Cloud file shown in place kept the placement turn")
            var followingOpenRan = false
            services.linkOpener.open(from: fixture.pane) { _, _ in followingOpenRan = true; return false }
            #expect(followingOpenRan, "a following open waited for a nonexistent Cloud file move")
        }
        let service = FilePageHandlers.service(name == "notes.md" ? .markdown : .editor, services)
        #expect(service.debugTabs.filter { $0.file == file }.count == 1, "a reused Cloud file must keep its tab")
    }

    @Test(arguments: [false, true])
    func openAsTextShowsCloudMarkdownSource(_ stringArgument: Bool) async throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let services = fixture.services
        let path = "/home/cmux/\(UUID().uuidString)/notes.md"
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: fixture.pane.paneKey),
                                          arguments: ["path": .string(path), "asText": stringArgument ? .string("true") : .bool(true)],
                                          origin: .cli)
        var refusal: String?
        let work = services.registry.capturingWork {
            refusal = services.registry.reportingRefusal {
                #expect(services.registry.perform("file.open", invocation: invocation))
            }
        }
        #expect(refusal == nil)
        for task in work { #expect(await task.value == nil) }
        let keys = services.pages.tabIDs(in: fixture.pane.paneKey)
        let key = try #require(keys.first { services.viewers.editorPages.file($0)?.path == path },
                               "Open as Text must select the Cloud file's code editor")
        #expect(!keys.contains { services.viewers.markdownPages.file($0)?.path == path })
        #expect(FilePageHandlers.file(ofTab: key, services) == nil,
                "the Cloud source must not become a local external-open URL")
    }

    @Test(arguments: [false, true])
    func sourcePageRoundTripPreservesCloudOrigin(_ localPane: Bool) throws {
        let fixture = try Self.fixture(localPane: localPane)
        defer { fixture.close() }
        let services = fixture.services
        let daemon = try #require(services.machines.remoteDaemons.first)
        let file = fixture.root.appending(path: "notes.md")
        try Data("local copy must not open".utf8).write(to: file)
        let rendered = services.viewers.markdownPages.open(file, in: fixture.pane, focus: true, on: daemon)
        let sourceInvocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: rendered), origin: .cli)
        #expect(services.registry.action(for: "browser.editSource")?.targetHidden?(sourceInvocation) == false)
        let sourceRefusal = services.registry.reportingRefusal {
            #expect(services.registry.perform("browser.editSource", invocation: sourceInvocation))
        }
        #expect(sourceRefusal == nil)
        let keys = services.pages.tabIDs(in: fixture.pane.paneKey)
        let source = try #require(keys.first { services.viewers.editorPages.file($0) == file })
        #expect(FilePageHandlers.file(ofTab: source, services) == nil, "source opened on this Mac")
        let pageInvocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: source), origin: .cli)
        #expect(services.registry.action(for: "file.openAsPage")?.targetHidden?(pageInvocation) == false)
        let pageRefusal = services.registry.reportingRefusal {
            #expect(services.registry.perform("file.openAsPage", invocation: pageInvocation))
        }
        #expect(pageRefusal == nil)
        #expect(services.viewers.markdownPages.debugTabs.filter { $0.file == file }.map(\.key) == [rendered],
                "the round trip must reuse the Cloud Markdown tab, not create a local copy")
        #expect(FilePageHandlers.file(ofTab: rendered, services) == nil)
    }

    @Test(arguments: ["report.html", "logo.svg"])
    func remoteWebSourceNeverOffersLocalRendering(_ name: String) throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let services = fixture.services
        let file = fixture.root.appending(path: name)
        try Data("local copy must not render".utf8).write(to: file)
        let source = services.viewers.editorPages.open(file, in: fixture.pane, focus: false, on: fixture.pane.daemon)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: source), origin: .cli)
        #expect(services.registry.action(for: "file.openAsPage")?.targetHidden?(invocation) == true)
        let refusal = services.registry.reportingRefusal {
            #expect(services.registry.perform("file.openAsPage", invocation: invocation))
        }
        #expect(refusal != nil)
        #expect(FilePageHandlers.file(ofTab: source, services) == nil)
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), arguments: FilePageKind.allCases)
    func remoteFilesInALocalPaneNeverPersistAsLocalPaths(_ kind: FilePageKind) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let pane = try #require(services.windows.active?.focusedPane)
            try #require(pane.daemon.isLocal && services.pages.keepsRoutes(pane.daemon))
            let root = FileManager.default.temporaryDirectory.appending(path: "cloud-file-route-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
            let service = FilePageHandlers.service(kind, services)
            let file = root.appending(path: "same-path.md")
            try Data("local copy".utf8).write(to: file)
            let local = service.open(file, in: pane, focus: false)
            #expect(!services.pages.tabIDs(in: pane.paneKey).contains(local), "local control must use a store tab")
            // A remote link can finish after its source closed and land in the active local pane.
            let remote = service.open(file, in: pane, focus: false, on: machine.daemon)
            #expect(remote != local)
            #expect(services.pages.tabIDs(in: pane.paneKey).contains(remote),
                    "remote content became a store route that relaunch would restore from this Mac")
            #expect(service.localFile(remote) == nil)
        }
    }

}
