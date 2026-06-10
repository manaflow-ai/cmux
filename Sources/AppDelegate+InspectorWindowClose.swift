import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Detached web inspector window close interception
extension AppDelegate {
    @discardableResult
    func handleDetachedInspectorWindowCloseAction(
        action: Selector,
        target: Any?,
        sender: Any?
    ) -> Bool {
        guard Thread.isMainThread else { return false }

        return MainActor.assumeIsolated {
            guard Self.shouldInterceptWindowCloseAction(
                action,
                target: target,
                sender: sender
            ) else { return false }
            guard let window = Self.actionWindow(
                target: target,
                sender: sender,
                allowFallback: Self.allowsWindowFallback(for: action)
            ),
                  BrowserPanel.isDetachedInspectorWindow(window) else { return false }

            for panel in allBrowserPanelsForInspectorWindowClose() {
                if panel.closeDeveloperToolsFromDetachedInspectorWindowUserAction(
                    window,
                    source: "sendAction.\(NSStringFromSelector(action))"
                ) {
#if DEBUG
                    cmuxDebugLog(
                        "browser.devtools detachedClose.action panel=\(panel.id.uuidString.prefix(5)) " +
                        "action=\(NSStringFromSelector(action)) window=\(window.windowNumber)"
                    )
#endif
                    return true
                }
            }

            return false
        }
    }

    private static func shouldInterceptWindowCloseAction(
        _ action: Selector,
        target: Any?,
        sender: Any?
    ) -> Bool {
        switch NSStringFromSelector(action) {
        case "__close", "performClose:":
            return true
        case "close", "close:":
            return actionWindow(target: target, sender: sender, allowFallback: false) != nil
        default:
            return false
        }
    }

    private static func allowsWindowFallback(for action: Selector) -> Bool {
        switch NSStringFromSelector(action) {
        case "__close", "performClose:":
            return true
        default:
            return false
        }
    }

    private static func actionWindow(
        target: Any?,
        sender: Any?,
        allowFallback: Bool = true
    ) -> NSWindow? {
        if let window = target as? NSWindow {
            return window
        }
        if let window = sender as? NSWindow {
            return window
        }
        if let view = sender as? NSView {
            return view.window
        }
        if let cell = sender as? NSCell {
            return cell.controlView?.window
        }
        if target == nil, sender is NSMenuItem {
            return NSApp.keyWindow ?? NSApp.mainWindow
        }
        return allowFallback ? (NSApp.keyWindow ?? NSApp.mainWindow) : nil
    }

    private func allBrowserPanelsForInspectorWindowClose() -> [BrowserPanel] {
        var candidateManagers: [TabManager] = []
        var seenManagers = Set<ObjectIdentifier>()
        var panels: [BrowserPanel] = []
        var seenPanels = Set<ObjectIdentifier>()

        func appendCandidate(_ manager: TabManager?) {
            guard let manager else { return }
            let identifier = ObjectIdentifier(manager)
            guard seenManagers.insert(identifier).inserted else { return }
            candidateManagers.append(manager)
        }

        appendCandidate(tabManager)
        for context in mainWindowContexts.values {
            appendCandidate(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            appendCandidate(route.tabManager)
        }

        for manager in candidateManagers {
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let browserPanel = panel as? BrowserPanel else { continue }
                    let identifier = ObjectIdentifier(browserPanel)
                    guard seenPanels.insert(identifier).inserted else { continue }
                    panels.append(browserPanel)
                }
            }
        }

        return panels
    }

}
