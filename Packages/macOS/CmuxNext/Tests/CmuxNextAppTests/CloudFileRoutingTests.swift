import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemonService
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

/// File actions keep a Cloud path on its machine, including paths absent from this Mac.
@MainActor @Suite(.serialized)
struct CloudFileRoutingTests {
    private struct Fixture {
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

    private static func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "cloud-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
        services.machines.add(machine)
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "Cloud terminal")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        machine.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: "cloud-files", name: "Cloud", screens: [screen])]))
        services.windows.registry.provisional["cloud-file-window"] = ["cloud-files"]
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "cloud-file-window"))
        services.windows.select("cloud-files", in: controller.state)
        controller.showWorkspace(requested: controller.state.workspaceID)
        let shown = try #require(controller.focusedPane)
        try #require(!shown.daemon.isLocal)
        let context = AppActionContext(services: services)
        AgentHandlers.bind(into: services.registry, context: context)
        ViewerHandlers.bind(into: services.registry, context: context)
        FilePageHandlers.bind(into: services.registry, context: context)
        return Fixture(services: services, controller: controller, pane: shown, root: root)
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
}
