import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - Socket command focus-mutation policy
extension TerminalController {
    private nonisolated static let socketCommandFocusAllowanceStackKey = "cmux.socketCommandFocusAllowanceStack"
    private nonisolated static let focusIntentV1Commands: Set<String> = [
        "focus_window",
        "select_workspace",
        "focus_surface",
        "focus_pane",
        "focus_surface_by_panel",
        "focus_webview",
        "focus_notification",
        "activate_app",
        "debug_right_sidebar_focus",
    ]

    private nonisolated static let focusIntentV2Methods: Set<String> = [
        "window.focus",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.group.focus",
        "surface.focus",
        "pane.focus",
        "pane.last",
        "file.open",
        "browser.focus_webview",
        "browser.focus",
        "browser.tab.switch",
        "notification.open",
        "notification.jump_to_unread",
        "debug.command_palette.toggle",
        "debug.notification.focus",
        "debug.app.activate",
        "debug.right_sidebar.focus",
        "feed.jump"
    ]

    nonisolated static func shouldSuppressSocketCommandActivation() -> Bool {
        !currentSocketCommandFocusAllowanceStack().isEmpty
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private nonisolated static func allowsInAppFocusMutationsForActiveSocketCommand() -> Bool {
        currentSocketCommandFocusAllowanceStack().last ?? false
    }

    func socketCommandAllowsInAppFocusMutations() -> Bool {
        Self.allowsInAppFocusMutationsForActiveSocketCommand()
    }

    func v2FocusAllowed(requested: Bool = true) -> Bool {
        requested && socketCommandAllowsInAppFocusMutations()
    }

    func v2MaybeFocusWindow(for tabManager: TabManager) {
        guard socketCommandAllowsInAppFocusMutations(),
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    func v2MaybeSelectWorkspace(_ tabManager: TabManager, workspace: Workspace) {
        guard socketCommandAllowsInAppFocusMutations() else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations(commandKey: String, isV2: Bool, params: [String: Any] = [:]) -> Bool {
        if isV2 {
            return focusIntentV2Methods.contains(commandKey)
                || explicitFocusParamAllowsFocus(commandKey: commandKey, params: params)
        }
        if commandKey == "right_sidebar" {
            return rightSidebarCommandAllowsInAppFocusMutations(args: params["args"] as? String ?? "")
        }
        return focusIntentV1Commands.contains(commandKey)
    }

    nonisolated static func rightSidebarCommandAllowsInAppFocusMutations(args: String) -> Bool {
        let parsed = RightSidebarRemoteRequest.parse(tokens: Self.tokenizeArgs(args))
        guard case .success(let request) = parsed else { return false }
        switch request.command {
        case .toggle, .show, .focus:
            return true
        case .setMode(_, let focus):
            return focus
        case .hide, .getState:
            return false
        }
    }

    nonisolated func withSocketCommandPolicy<T>(commandKey: String, isV2: Bool, params: [String: Any] = [:], _ body: () -> T) -> T {
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(commandKey: commandKey, isV2: isV2, params: params)
        var stack = Self.currentSocketCommandFocusAllowanceStack()
        stack.append(allowsFocusMutation)
        Self.setCurrentSocketCommandFocusAllowanceStack(stack)
        defer {
            var stack = Self.currentSocketCommandFocusAllowanceStack()
            if !stack.isEmpty {
                _ = stack.popLast()
            }
            Self.setCurrentSocketCommandFocusAllowanceStack(stack)
        }
        return body()
    }

    nonisolated static func currentSocketCommandFocusAllowanceStack() -> [Bool] {
        Thread.current.threadDictionary[socketCommandFocusAllowanceStackKey] as? [Bool] ?? []
    }

    private nonisolated static func setCurrentSocketCommandFocusAllowanceStack(_ stack: [Bool]) {
        if stack.isEmpty {
            Thread.current.threadDictionary.removeObject(forKey: socketCommandFocusAllowanceStackKey)
        } else {
            Thread.current.threadDictionary[socketCommandFocusAllowanceStackKey] = stack
        }
    }

    nonisolated static func withSocketCommandPolicyStack<T>(_ stack: [Bool], _ body: () -> T) -> T {
        let previous = currentSocketCommandFocusAllowanceStack()
        setCurrentSocketCommandFocusAllowanceStack(stack)
        defer { setCurrentSocketCommandFocusAllowanceStack(previous) }
        return body()
    }

#if DEBUG
    static func debugSocketCommandPolicySnapshot(
        commandKey: String,
        isV2: Bool,
        params: [String: Any] = [:]
    ) -> (insideSuppressed: Bool, insideAllowsFocus: Bool, outsideSuppressed: Bool, outsideAllowsFocus: Bool) {
        var insideSuppressed = false
        var insideAllowsFocus = false
        _ = Self.shared.withSocketCommandPolicy(commandKey: commandKey, isV2: isV2, params: params) {
            insideSuppressed = Self.shouldSuppressSocketCommandActivation()
            insideAllowsFocus = Self.socketCommandAllowsInAppFocusMutations()
            return 0
        }
        return (
            insideSuppressed: insideSuppressed,
            insideAllowsFocus: insideAllowsFocus,
            outsideSuppressed: Self.shouldSuppressSocketCommandActivation(),
            outsideAllowsFocus: Self.socketCommandAllowsInAppFocusMutations()
        )
    }

    static func debugNotifyTargetQueuedResponseForTesting(_ args: String) -> String {
        Self.shared.notifyTargetQueued(args)
    }
#endif

}
