import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

#if DEBUG
/// The restore journey (scripts/cmux-next/restore-journey.py, cx-mzuqi) reads a window's
/// full screen, sidebar width and display from `debug.windows`, and a terminal's font zoom
/// from `debug.surfaces`, before a quit and after the relaunch. The window record saves all
/// of them; the socket must report what the window shows now. The boundary: the app's debug
/// socket methods on a real same-tree daemon, a window on screen, and the app's own actions
/// for the font zoom.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct RestoreWindowFieldsDebugTests {
    @Test func debugSocketReportsTheWindowAndFontZoomTheRecordSaves() async throws {
        try await Self.withApp { services, router in
            let controller = try #require(services.windows.active)
            try #require(controller.window).setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: true)
            let timer = PhaseTimer("rwf-body")
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(), into: controller.state.id)
            timer.mark("created")
            try await Self.until({ Self.livePane(controller, workspace: id) != nil })
            timer.mark("pane-live")
            let pane = try #require(Self.livePane(controller, workspace: id))
            // The font size actions take the terminal's tab.
            let tab = try #require(pane.selectedTab?.id)

            // A person drags the sidebar to 300 points and zooms the terminal twice (Cmd-+).
            controller.sidebar.model.width = 300
            for _ in 0..<2 {
                #expect(services.registry.perform("terminal.increaseFontSize",
                                                  invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .cli)))
            }

            try await Self.until({
                let report = try await router.call("debug.windows")
                return Self.windowEntry(report, controller.state.id)?["sidebar_width"] == .number(300)
            }, report: { String(describing: try await router.call("debug.windows")) })
            timer.mark("sidebar-reported")
            let windows = try await router.call("debug.windows")
            let window = try #require(Self.windowEntry(windows, controller.state.id))
            #expect(window["full_screen"] == .bool(false))
            #expect(window["sidebar_hidden"] == .bool(false))
            #expect(windows.objectValue?["displays"] == .number(Double(NSScreen.screens.count)))
            // The display the window is on, as the record names it (a display UUID), or null
            // on a host that gives the window no screen.
            if controller.window?.screen != nil {
                #expect(window["display"]?.stringValue?.isEmpty == false, "\(window)")
            } else {
                #expect(window["display"] == .null)
            }

            try await Self.until({
                let report = try await router.call("debug.surfaces")
                return (Self.fontScale(report, pane: pane.paneKey) ?? 0) > 1.05
            }, report: { String(describing: try await router.call("debug.surfaces")) })
            timer.mark("font-up")
            // Back to the configured size: the scale reads 1.
            #expect(services.registry.perform("terminal.resetFontSize",
                                              invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .cli)))
            try await Self.until({
                let report = try await router.call("debug.surfaces")
                return Self.fontScale(report, pane: pane.paneKey) == 1
            }, report: { String(describing: try await router.call("debug.surfaces")) })
            timer.mark("font-reset")
        }
    }

    private static func windowEntry(_ report: CmuxNextSettings.JSONValue, _ id: String) -> [String: CmuxNextSettings.JSONValue]? {
        report.objectValue?["windows"]?.arrayValue?.compactMap(\.objectValue).first { $0["id"] == .string(id) }
    }

    private static func fontScale(_ report: CmuxNextSettings.JSONValue, pane: String) -> Double? {
        let panes = report.objectValue?["windows"]?.arrayValue?.compactMap { $0.objectValue?["panes"]?.arrayValue }.flatMap { $0 } ?? []
        return panes.compactMap(\.objectValue).first { $0["pane"] == .string(pane) }?["font_scale"]?.doubleValue
    }

    /// The shown pane of `workspace` once its terminal draws a grid.
    private static func livePane(_ controller: WindowController, workspace: String) -> PaneController? {
        if controller.workspaceContent?.workspace.id != workspace {
            controller.services.windows.show(workspaceID: workspace, in: controller.state)
        }
        guard let content = controller.workspaceContent, content.workspace.id == workspace,
              let pane = content.panes.values.first, pane.surfaceStatus.terminal?.grid != nil else { return nil }
        return pane
    }

    private static func until(_ condition: () async throws -> Bool, within timeout: Duration = .seconds(60),
                              report: () async throws -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(try await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let met = try await condition()
        let detail = met ? "" : try await report()
        try #require(met, "timed out: \(detail)", sourceLocation: sourceLocation)
    }

    struct Router {
        let router: ControlRouter

        func call(_ method: String, _ params: [String: CmuxNextSettings.JSONValue] = [:]) async throws -> CmuxNextSettings.JSONValue {
            try await router.handle(ControlRequest(id: "1", method: method, params: params)).get()
        }
    }

    /// The app's services on a fresh same-tree daemon with its window on screen, and a control
    /// router with the app's window and surface debug methods.
    private static func withApp(_ body: (AppServices, Router) async throws -> Void) async throws {
        let timer = PhaseTimer("rwf")
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-rjfields-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-rjfields-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil)
        router.register(DebugWindowsControl.methods(services))
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let watches = [timer.watch("restored") { services.windows.restored }, timer.watch("connected") { services.daemon.connection != nil },
                       timer.watch("store-loaded") { services.daemon.store.isLoaded }]
        defer { for watch in watches { watch.cancel() } }
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let result: Result<Void, any Error>
        do {
            // Launch is over: its first workspace (a New Tab page) was made and shown. Before
            // that, `restore()` could land it over the test's workspace mid-body.
            try await until({ services.windows.active?.window != nil && services.daemon.connection != nil && !services.windows.registry.isLaunching },
                            within: .seconds(90))
            timer.mark("launch-over")
            result = .success(try await body(services, Router(router: router)))
            timer.mark("body")
        } catch { result = .failure(error); timer.mark("body-threw") }
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        timer.mark("stopped")
        try result.get()
    }
}
#endif
