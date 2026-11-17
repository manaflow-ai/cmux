import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemonService
import CmuxNextTabs
import CmuxNextTestSupport
import CmuxNextVSCodeServer
import Foundation
import Testing

/// Leo, 2026-11-17: "just... stop showijg the toggle on gui." The extension rows, Open Folder in VS
/// Code (Inline), the vault's row actions and Hibernate Tab leave the menus and the palette where they
/// cannot run, decided by the run's own lookup (`ActionRegistry.gate(_:unlessFinds:)`), instead of
/// being shown and answering with a toast that says to go elsewhere. A CLI or MCP run still hears why.
@MainActor @Suite(.serialized, .closesItsWindows)
struct RowsLeaveWhereTheyCannotRunTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    private static func reason(_ id: ActionID, _ invocation: ActionInvocation = ActionInvocation(), in registry: ActionRegistry) -> String? {
        registry.withoutRefusals { ActionTargetReasons.reason(for: id, invocation: invocation, in: registry) }
    }

    /// The gate: a lookup that throws an ``ActionFailure`` leaves the row out and names why; a
    /// not-found failure or any other error stays the run's answer; a lookup that finds lets it run.
    @Test func aLookupThatThrowsGatesTheRow() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("newWindow") {}
        var failure: (any Error)? = ActionFailure(message: "No window here.")
        registry.gate(["newWindow"], unlessFinds: { _ in if let failure { throw failure } })
        #expect(Self.reason("newWindow", in: registry) == "No window here.")
        #expect(ActionTargetVisibility.isHidden("newWindow", invocation: ActionInvocation(), in: registry))
        failure = ActionFailure.notFound("Gone.")
        #expect(Self.reason("newWindow", in: registry) == nil)
        failure = CocoaError(.fileNoSuchFile)
        #expect(Self.reason("newWindow", in: registry) == nil)
        failure = nil
        #expect(Self.reason("newWindow", in: registry) == nil)
        #expect(!ActionTargetVisibility.isHidden("newWindow", invocation: ActionInvocation(), in: registry))
    }

    /// No Chromium tab focused or targeted: the extension rows that act on one leave the menus and the
    /// palette (no "needs a Chromium tab" toast); Manage Extensions and the Web Store, which open a
    /// new tab, stay.
    @Test func extensionRowsNeedAChromiumTab() {
        let registry = Self.services().registry
        let tabRows: [ActionID] = [
            "browser.extensions.menu", "browser.extension.run", "browser.extension.move", "browser.extensions.loadUnpacked",
            "browser.extension.options", "browser.extension.pin", "browser.extension.unpin", "browser.extension.enable",
            "browser.extension.disable", "browser.extension.remove", "browser.extension.reload", "browser.extension.command",
        ]
        for id in tabRows {
            #expect(Self.reason(id, in: registry) == ExtensionStrings.needsChromiumTab, "\(id)")
            #expect(ActionTargetVisibility.isHidden(id, invocation: ActionInvocation(), in: registry), "\(id) stays in the menu")
        }
        for id: ActionID in ["browser.extensions.manage", "browser.extensions.webStore"] {
            #expect(Self.reason(id, in: registry) == nil, "\(id) needs no Chromium tab")
        }
    }

    /// The vault's row actions with no session named and none selected leave the menus; naming one
    /// (the CLI's `--arg session=`) is never held back by the selection, and a name that matches
    /// nothing stays the run's `not_found`.
    @Test func vaultRowActionsNeedASession() {
        let registry = Self.services().registry
        for id: ActionID in ["vaultFocusSession", "vaultOpenSession", "vaultResumeInNewWorkspace", "vaultCopyResumeCommand", "vaultOpenPullRequest"] {
            #expect(Self.reason(id, in: registry) == VaultStrings.noSessionSelected, "\(id)")
            #expect(ActionTargetVisibility.isHidden(id, invocation: ActionInvocation(), in: registry), "\(id) stays in the menu")
            let named = ActionInvocation(arguments: ["session": .string("claude:abc")])
            #expect(Self.reason(id, named, in: registry) == nil, "\(id) with a session named")
        }
    }

    /// Restart VS Code Inline Server and Open Folder in VS Code (Inline) are offered exactly when
    /// this Mac has VS Code (the lookup the run takes, `VSCodeAppLocator`).
    @Test func vscodeRowsNeedVSCode() {
        let registry = Self.services().registry
        let installed = VSCodeAppLocator { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.installed() != nil
        #expect(Self.reason("palette.vscodeServeWebRestart", in: registry) == (installed ? nil : VSCodeInlineStrings.notInstalled))
        #expect(Self.reason("palette.openFolderInVSCodeInline", in: registry) == (installed ? nil : VSCodeInlineStrings.notInstalled))
    }

    /// The shown tab has nothing to hibernate: Hibernate Tab leaves its menu and the palette, and the
    /// CLI hears "Only a hidden tab can hibernate."
    @Test func hibernateTabLeavesAShownTab() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let pane = try #require(services.windows.active?.workspaceContent?.panes.values.first)
            let id = try #require(pane.stripModel.selectedID)
            let onTab = ActionInvocation(target: ActionTargetRef(kind: .tab, id: id.rawValue))
            #expect(Self.reason("hibernateTab", onTab, in: services.registry) == RefusalStrings.hibernateVisibleTab)
            #expect(ActionTargetVisibility.isHidden("hibernateTab", invocation: onTab, in: services.registry))
            #expect(Self.reason("hibernateTab", in: services.registry) == RefusalStrings.hibernateVisibleTab, "the palette offers it")
        }
    }
}
