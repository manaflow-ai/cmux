import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Testing

/// Lane 20: Cmd-W in a window of its own (Debug Settings, the App Store,
/// onboarding, an undocked inspector) closed the selected tab of the last
/// main window. The window key table (`WindowKeyTable`): in every kind but
/// `main`, every close action closes the window, like its close button,
/// and never runs on a main window. These ran against `StandaloneWindowRule`
/// before the table replaced it; the standalone window here has no kind
/// (the table's fallback), `installedKindsBehaveTheSame` repeats them for a
/// window installed through the window kit.
@MainActor
@Suite(.serialized)
struct WindowKeyTableTests {
    /// Counts the runs of the main-window handlers it replaces.
    final class Spy {
        var runs: [String: Int] = [:]
    }

    final class Flag {
        var value = false
    }

    /// A registered main window, last active, and a standalone titled
    /// window that is key.
    private func world(kind: WindowKind? = nil) async throws -> (AppServices, NSWindow) {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let main = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(main)
        let standalone = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        standalone.isReleasedWhenClosed = false
        if let kind { standalone.install(kind: kind, content: NSView(), scope: .app) }
        services.keyWindowSource = { standalone }
        return (services, standalone)
    }

    /// Replaces the handlers of `ids` with counters.
    private func spy(_ services: AppServices, _ ids: [String]) -> Spy {
        let spy = Spy()
        for id in ids {
            services.registry.bind(ActionID(rawValue: id), invoke: { _ in spy.runs[id, default: 0] += 1 })
        }
        return spy
    }

    private func closes(_ window: NSWindow, during body: () -> Void) -> Bool {
        let flag = Flag()
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                           queue: nil) { _ in MainActor.assumeIsolated { flag.value = true } }
        defer { NotificationCenter.default.removeObserver(token) }
        body()
        return flag.value
    }

    /// Every close action of the catalog, as the rule sees it.
    private static func closeActions() -> [String] {
        ActionRegistry.standard().descriptors.map(\.id).filter(WindowKeyTable.isClose).map(\.rawValue)
    }

    @Test func theCatalogsCloseActionsAreAllCovered() {
        let ids = Set(Self.closeActions())
        for id in ["closeTab", "closePane", "closeWorkspace", "closeWindow", "palette.closeOtherWorkspaces",
                   "workspace.closeOthersInGroup", "tabGroup.close", "workspaceGroup.closeWorkspaces"] {
            #expect(ids.contains(id), "\(id)")
        }
        #expect(!ids.contains("reopenClosedWorkspace") && !ids.contains("recentlyClosed"))
    }

    @Test func everyCloseActionClosesTheKeyStandaloneWindow() async throws {
        for id in Self.closeActions() {
            let (services, standalone) = try await world()
            let spy = spy(services, [id])
            // Cmd-W and friends arrive as a user run without a target.
            let closed = closes(standalone) { services.registry.perform(ActionID(rawValue: id), invocation: ActionInvocation()) }
            #expect(closed, "\(id) closes the key standalone window")
            #expect(spy.runs[id] == nil, "\(id) ran on the main window")
            #expect(services.windows.controllers.count == 1, "\(id) closed the main window")
        }
    }

    @Test func theMenuKeyEquivalentPathClosesTheStandaloneWindow() async throws {
        let (services, standalone) = try await world()
        let spy = spy(services, ["closeTab"])
        let registry = services.registry
        let item = try #require(registry.makeMenuItem(for: "closeTab"))
        let target = try #require(item.target as? any NSMenuItemValidation)
        let action = try #require(item.action)
        let previous = registry.isDispatchingKeyDown
        registry.isDispatchingKeyDown = { true }
        defer { registry.isDispatchingKeyDown = previous }
        #expect(target.validateMenuItem(item), "Close Tab stays enabled: it closes the standalone window")
        let closed = closes(standalone) { _ = (item.target as? NSObject)?.perform(action, with: item) }
        #expect(closed)
        #expect(spy.runs["closeTab"] == nil)
    }

    @Test func aSheetOrPanelOverTheStandaloneWindowRunsNothing() async throws {
        let (services, standalone) = try await world()
        let spy = spy(services, ["closeTab"])
        let panel = NSPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 100, height: 80),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        standalone.addChildWindow(panel, ordered: .above)
        defer { standalone.removeChildWindow(panel) }
        services.keyWindowSource = { panel }
        let item = try #require(services.registry.makeMenuItem(for: "closeTab"))
        let target = try #require(item.target as? any NSMenuItemValidation)
        #expect(target.validateMenuItem(item), "no beep: the key is consumed")
        let closed = closes(standalone) { services.registry.perform("closeTab", invocation: ActionInvocation()) }
        #expect(!closed)
        #expect(spy.runs["closeTab"] == nil, "a panel over a standalone window never reaches the main window")
    }

    @Test func destructiveContentActionsAreDisabledAndCloseActionsCloseTheWindow() {
        let table = WindowKeyTable(registry: ActionRegistry.standard())
        let content = table.registry.descriptors.first {
            $0.isDestructive && !WindowKeyTable.contentTargets.isDisjoint(with: $0.targets) && !WindowKeyTable.isClose($0.id)
                && !WindowKeyTable.appLevel.contains($0.id)
        }
        if let content {
            #expect(table.behavior(for: content.id, in: .settings) == .disabled(reason: MiscHandlerStrings.notInThisWindow))
            #expect(table.behavior(for: content.id, in: .main) == .run)
        }
        #expect(table.behavior(for: "closeTab", in: .settings) == .closeWindow)
        #expect(table.behavior(for: "closeTab", in: .settings, overRoot: true) == .consume)
        #expect(table.behavior(for: "closeTab", in: .main) == .run)
        #expect(table.behavior(for: "newTab", in: .settings) == .run, "Cmd-T in Settings opens a tab in the main window")
        #expect(table.behavior(for: "quit", in: .devTools) == .run)
    }

    @Test func aDestructiveContentActionIsOffAndAnAccountActionIsNot() async throws {
        let (services, _) = try await world()
        let registry = services.registry
        let table = WindowKeyTable(registry: registry)
        let content = try #require(registry.descriptors.first { $0.isDestructive && !WindowKeyTable.contentTargets.isDisjoint(with: $0.targets) && !WindowKeyTable.isClose($0.id) && !WindowKeyTable.appLevel.contains($0.id) })
        #expect(table.destroysContent(content.id))
        let spy = spy(services, [content.id.rawValue])
        if let item = registry.makeMenuItem(for: content.id), let target = item.target as? any NSMenuItemValidation {
            #expect(!target.validateMenuItem(item), "\(content.id) is off while a standalone window is key")
        }
        let refusal = registry.capturingRefusal { registry.perform(content.id, invocation: ActionInvocation()) }
        #expect(refusal == MiscHandlerStrings.notInThisWindow)
        #expect(spy.runs[content.id.rawValue] == nil)
        if let other = registry.descriptors.first(where: { $0.isDestructive && WindowKeyTable.contentTargets.isDisjoint(with: $0.targets) }) {
            #expect(!table.destroysContent(other.id), "\(other.id) is not main window content")
        }
    }

    @Test func anExplicitTargetStillRunsFromAStandaloneWindow() async throws {
        let (services, standalone) = try await world()
        let spy = spy(services, ["closeTab"])
        let closed = closes(standalone) {
            services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: "surface:4")))
        }
        #expect(spy.runs["closeTab"] == 1, "a targeted close (context menu) closes that tab")
        #expect(!closed)
    }

    @Test func automationWithoutATargetIgnoresTheKeyWindow() async throws {
        let (services, standalone) = try await world()
        let spy = spy(services, ["closeTab"])
        let closed = closes(standalone) { services.registry.perform("closeTab", invocation: ActionInvocation(origin: .cli)) }
        #expect(spy.runs["closeTab"] == 1, "a CLI close means the focused tab of the active main window")
        #expect(!closed)
    }

    @Test func mainWindowsAndTheirPanelsAreNotStandalone() async throws {
        let (services, _) = try await world()
        let main = try #require(services.windows.controllers.first?.window)
        services.keyWindowSource = { main }
        #expect(services.keyWindowRole?.close == .contentFirst)
        let palette = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        main.addChildWindow(palette, ordered: .above)
        defer { main.removeChildWindow(palette) }
        services.keyWindowSource = { palette }
        #expect(services.keyWindowRole?.close == .contentFirst)
        let borderless = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        services.keyWindowSource = { borderless }
        // A kind-less window no main window owns is a window of its own
        // (PopupAndKindlessKeyTests), never main window content.
        #expect(services.keyWindowRole?.close == .window)
    }

    /// Every kind but main, installed through the window kit: Cmd-W closes
    /// it and the main window's tab survives; a panel over it consumes.
    @Test func installedKindsBehaveTheSame() async throws {
        for kind in WindowKind.allCases where kind != .main {
            let (services, standalone) = try await world(kind: kind)
            let spy = spy(services, ["closeTab"])
            #expect(closes(standalone) { services.registry.perform("closeTab", invocation: ActionInvocation()) }, "\(kind)")
            #expect(spy.runs["closeTab"] == nil, "\(kind)")
            let panel = NSPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 100, height: 80),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            standalone.addChildWindow(panel, ordered: .above)
            services.keyWindowSource = { panel }
            #expect(!closes(standalone) { services.registry.perform("closeTab", invocation: ActionInvocation()) }, "\(kind)")
            #expect(spy.runs["closeTab"] == nil, "\(kind)")
            standalone.removeChildWindow(panel)
        }
    }
}
