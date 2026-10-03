import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Lane 20: Cmd-W in a window of its own (Debug Settings, the App Store,
/// onboarding, an undocked inspector) closed the selected tab of the last
/// main window. A standalone window is its own only pane: every close
/// action closes it, like its close button, and never runs on a main window.
@MainActor
@Suite(.serialized)
struct StandaloneWindowCloseTests {
    /// Counts the runs of the main-window handlers it replaces.
    final class Spy {
        var runs: [String: Int] = [:]
    }

    final class Flag {
        var value = false
    }

    /// A registered main window, last active, and a standalone titled
    /// window that is key.
    private func world() async throws -> (AppServices, NSWindow) {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let main = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(main)
        let standalone = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        standalone.isReleasedWhenClosed = false
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
        ActionRegistry.standard().descriptors.map(\.id).filter(StandaloneWindowRule.isClose).map(\.rawValue)
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

    @Test func destructiveActionsAreDisabledWhileAStandaloneWindowIsKey() {
        let kind = StandaloneWindowRule.Kind(closes: false, destroysContent: true)
        #expect(StandaloneWindowRule.decide(kind, origin: .user, hasTarget: false, keyWindow: .standalone) == .disabled)
        #expect(StandaloneWindowRule.decide(kind, origin: .user, hasTarget: false, keyWindow: nil) == .pass)
        #expect(StandaloneWindowRule.decide(kind, origin: .user, hasTarget: true, keyWindow: .standalone) == .pass)
        let plain = StandaloneWindowRule.Kind(closes: false, destroysContent: false)
        #expect(StandaloneWindowRule.decide(plain, origin: .user, hasTarget: false, keyWindow: .standalone) == .pass)
    }

    @Test func aDestructiveContentActionIsOffAndAnAccountActionIsNot() async throws {
        let (services, _) = try await world()
        let registry = services.registry
        let content = try #require(registry.descriptors.first { $0.isDestructive && !StandaloneWindowRule.contentTargets.isDisjoint(with: $0.targets) && !StandaloneWindowRule.isClose($0.id) })
        #expect(StandaloneWindowRule.kind(content.id, registry: registry).destroysContent)
        let spy = spy(services, [content.id.rawValue])
        if let item = registry.makeMenuItem(for: content.id), let target = item.target as? any NSMenuItemValidation {
            #expect(!target.validateMenuItem(item), "\(content.id) is off while a standalone window is key")
        }
        let refusal = registry.capturingRefusal { registry.perform(content.id, invocation: ActionInvocation()) }
        #expect(refusal == MiscHandlerStrings.noPane)
        #expect(spy.runs[content.id.rawValue] == nil)
        if let other = registry.descriptors.first(where: { $0.isDestructive && StandaloneWindowRule.contentTargets.isDisjoint(with: $0.targets) }) {
            #expect(!StandaloneWindowRule.kind(other.id, registry: registry).destroysContent, "\(other.id) is not main window content")
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
        #expect(services.keyStandaloneWindow == nil)
        let palette = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        main.addChildWindow(palette, ordered: .above)
        defer { main.removeChildWindow(palette) }
        services.keyWindowSource = { palette }
        #expect(services.keyStandaloneWindow == nil)
        let borderless = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        services.keyWindowSource = { borderless }
        #expect(services.keyStandaloneWindow == nil)
    }
}
