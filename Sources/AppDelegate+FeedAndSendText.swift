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


// MARK: - Feed requests, ReactGrab, and terminal text send
extension AppDelegate {
    @objc func handleFeedRequestFocus(_ notification: Notification) {
        guard let workspaceId = notification.userInfo?["workspaceId"] as? String,
              let surfaceId = notification.userInfo?["surfaceId"] as? String
        else { return }

        // Invoke the existing V2 commands so the Feed-layer focus request
        // goes through the same code path as a socket-initiated focus.
        // Serialize through JSON so we reuse the v2 command parser.
        let controller = TerminalController.shared
        let invoke: (String, [String: Any]) -> Void = { method, params in
            let payload: [String: Any] = [
                "id": UUID().uuidString,
                "method": method,
                "params": params
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            _ = controller.handleSocketLine(line)
        }
        invoke("workspace.select", ["workspace_id": workspaceId])
        invoke("surface.focus", ["surface_id": surfaceId])
        // Flash the terminal's own focus ring (same visual as
        // cmd+shift+H / Flash Focused Panel) so the user's eye is
        // pulled to the terminal content the Feed jumped to.
        invoke("surface.trigger_flash", ["surface_id": surfaceId])
    }

    @objc func handleFeedRequestSendText(_ notification: Notification) {
        guard let surfaceId = notification.userInfo?["surfaceId"] as? String,
              let text = notification.userInfo?["text"] as? String,
              !text.isEmpty
        else { return }

        let controller = TerminalController.shared
        let invoke: (String, [String: Any]) -> Void = { method, params in
            let payload: [String: Any] = [
                "id": UUID().uuidString,
                "method": method,
                "params": params,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            _ = controller.handleSocketLine(line)
        }
        // Terminal-mode Return is CR. sendNamedKey "Return" also works
        // but one send_text is atomic, so append CR directly.
        invoke("surface.send_text", [
            "surface_id": surfaceId,
            "text": text + "\r",
        ])
    }

    @objc func handleReactGrabDidCopySelection(_ notification: Notification) {
        let browserPanelId = notification.userInfo?[ReactGrabPastebackNotificationKey.browserPanelId] as? UUID
        guard let workspaceId = notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID,
              let returnPanelId = notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID,
              let content = notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String else {
#if DEBUG
            cmuxDebugLog(
                "reactGrab.pasteback h3.didCopy.drop " +
                "reason=missingNotificationFields " +
                "workspace=\(Self.debugShortId(notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID)) " +
                "browser=\(Self.debugShortId(browserPanelId)) " +
                "return=\(Self.debugShortId(notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID)) " +
                "hasContent=\((notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String) != nil ? 1 : 0)"
            )
#endif
            return
        }

        guard let manager = tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
#if DEBUG
            cmuxDebugLog(
                "reactGrab.pasteback h3.didCopy.drop " +
                "reason=missingWorkspace workspace=\(Self.debugShortId(workspaceId)) " +
                "browser=\(Self.debugShortId(browserPanelId)) return=\(Self.debugShortId(returnPanelId))"
            )
#endif
            return
        }

        guard workspace.terminalPanel(for: returnPanelId) != nil else {
#if DEBUG
            cmuxDebugLog(
                "reactGrab.pasteback h3.didCopy.drop " +
                "reason=missingReturnTerminal workspace=\(Self.debugShortId(workspaceId)) " +
                "browser=\(Self.debugShortId(browserPanelId)) return=\(Self.debugShortId(returnPanelId)) " +
                "focused=\(Self.debugShortId(workspace.focusedPanelId))"
            )
#endif
            return
        }

#if DEBUG
        cmuxDebugLog(
            "reactGrab.pasteback h3.didCopy " +
            "workspace=\(Self.debugShortId(workspaceId)) " +
            "browser=\(Self.debugShortId(browserPanelId)) " +
            "return=\(Self.debugShortId(returnPanelId)) " +
            "focusedBefore=\(Self.debugShortId(workspace.focusedPanelId)) len=\(content.count)"
        )
#endif
        manager.focusTab(workspaceId, surfaceId: returnPanelId, suppressFlash: true)
#if DEBUG
        cmuxDebugLog(
            "reactGrab.pasteback h1.focusRequested " +
            "workspace=\(Self.debugShortId(workspaceId)) " +
            "return=\(Self.debugShortId(returnPanelId)) " +
            "focusedAfterRequest=\(Self.debugShortId(workspace.focusedPanelId))"
        )
#endif
        sendTextWhenReady(content, to: workspace, preferredPanelId: returnPanelId)
    }

    nonisolated private static func debugShortId(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(5)) } ?? "nil"
    }

    static func resolveTerminalPanelForTextSend(in tab: Tab, preferredPanelId: UUID? = nil) -> TerminalPanel? {
        if let preferredPanelId {
            return tab.terminalPanel(for: preferredPanelId)
        }
        return tab.focusedTerminalPanel
    }

    func sendTextWhenReady(
        _ text: String,
        to tab: Tab,
        preferredPanelId: UUID? = nil,
        beforeSend: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        let isReactGrabPasteback = preferredPanelId != nil
#if DEBUG
        let initialTargetPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        )
        if isReactGrabPasteback {
            cmuxDebugLog(
                "reactGrab.pasteback h2.send.start " +
                "workspace=\(Self.debugShortId(tab.id)) " +
                "preferred=\(Self.debugShortId(preferredPanelId)) " +
                "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                "focusedTerminal=\(Self.debugShortId(tab.focusedTerminalPanel?.id)) " +
                "resolved=\(Self.debugShortId(initialTargetPanel?.id)) " +
                "surfaceReady=\(initialTargetPanel?.surface.surface != nil ? 1 : 0) len=\(text.count)"
            )
        }
#endif
        if let terminalPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        ),
           terminalPanel.isAgentHibernated {
            beforeSend?()
            if !terminalPanel.sendText(text) {
                onFailure?()
            }
            return
        }

        if let terminalPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        ),
           terminalPanel.surface.surface != nil {
#if DEBUG
            if isReactGrabPasteback {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.send.immediate " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) len=\(text.count)"
                )
            }
#endif
            beforeSend?()
            let didSend = terminalPanel.sendText(text)
#if DEBUG
            if isReactGrabPasteback, didSend {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.send.sent " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) mode=immediate len=\(text.count)"
                )
            }
#endif
            if !didSend {
                onFailure?()
            }
            return
        }

        var resolved = false
        var readyObserver: NSObjectProtocol?
        var focusObserver: NSObjectProtocol?
        var firstResponderObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func cleanupObservers() {
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
            }
            if let firstResponderObserver {
                NotificationCenter.default.removeObserver(firstResponderObserver)
            }
            panelsCancellable?.cancel()
        }

        func finishIfReady() {
            let terminalPanel = Self.resolveTerminalPanelForTextSend(
                in: tab,
                preferredPanelId: preferredPanelId
            )
#if DEBUG
            if isReactGrabPasteback {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.finishIfReady " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "preferred=\(Self.debugShortId(preferredPanelId)) " +
                    "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                    "resolved=\(Self.debugShortId(terminalPanel?.id)) " +
                    "surfaceReady=\(terminalPanel?.surface.surface != nil ? 1 : 0) alreadyResolved=\(resolved ? 1 : 0)"
                )
            }
#endif
            guard !resolved,
                  let terminalPanel,
                  terminalPanel.surface.surface != nil else { return }
            resolved = true
            cleanupObservers()
            beforeSend?()
            let didSend = terminalPanel.sendText(text)
#if DEBUG
            if isReactGrabPasteback, didSend {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.send.sent " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) mode=delayed len=\(text.count)"
                )
            }
#endif
            if !didSend {
                onFailure?()
            }
        }

        panelsCancellable = tab.$panels
            .map { _ in () }
            .sink { _ in
#if DEBUG
                if isReactGrabPasteback {
                    cmuxDebugLog(
                        "reactGrab.pasteback h2.panelsChanged " +
                        "workspace=\(Self.debugShortId(tab.id)) " +
                        "focused=\(Self.debugShortId(tab.focusedPanelId))"
                    )
                }
#endif
                finishIfReady()
            }
        if isReactGrabPasteback {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tab.id,
                      let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                    return
                }
#if DEBUG
                cmuxDebugLog(
                    "reactGrab.pasteback h1.focusEvent " +
                    "workspace=\(Self.debugShortId(candidateTabId)) " +
                    "surface=\(Self.debugShortId(candidateSurfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(candidateSurfaceId == preferredPanelId ? 1 : 0)"
                )
#endif
            }
            firstResponderObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidBecomeFirstResponderSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tab.id,
                      let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                    return
                }
#if DEBUG
                cmuxDebugLog(
                    "reactGrab.pasteback h1.firstResponderEvent " +
                    "workspace=\(Self.debugShortId(candidateTabId)) " +
                    "surface=\(Self.debugShortId(candidateSurfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(candidateSurfaceId == preferredPanelId ? 1 : 0)"
                )
#endif
            }
        }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  workspaceId == tab.id else { return }
            let surfaceId = note.userInfo?["surfaceId"] as? UUID
#if DEBUG
            if isReactGrabPasteback {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.surfaceReadyEvent " +
                    "workspace=\(Self.debugShortId(workspaceId)) " +
                    "surface=\(Self.debugShortId(surfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(surfaceId == preferredPanelId ? 1 : 0)"
                )
            }
#endif
            if let preferredPanelId,
               let surfaceId,
               surfaceId != preferredPanelId {
                return
            }
            finishIfReady()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !resolved {
                resolved = true
#if DEBUG
                if isReactGrabPasteback {
                    cmuxDebugLog(
                        "reactGrab.pasteback h2.send.timeout " +
                        "workspace=\(Self.debugShortId(tab.id)) " +
                        "preferred=\(Self.debugShortId(preferredPanelId)) " +
                        "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                        "focusedTerminal=\(Self.debugShortId(tab.focusedTerminalPanel?.id))"
                    )
                }
#endif
                cleanupObservers()
                NSLog("Command send: surface not ready after 3.0s")
                onFailure?()
            }
        }
    }

    static func feedPermissionNotificationCategoryIds() -> [String] {
        [
            "CMUXFeedPermission",
            "CMUXFeedPermissionDeny",
            "CMUXFeedPermissionOnce",
            "CMUXFeedPermissionAlways",
            "CMUXFeedPermissionAll",
            "CMUXFeedPermissionOnceAlways",
            "CMUXFeedPermissionOnceAll",
            "CMUXFeedPermissionAlwaysAll",
            "CMUXFeedPermissionOnceAlwaysAll",
        ]
    }

    /// Routes a notification action identifier like
    /// `feed.permission.once` back to `FeedCoordinator.deliverReply`.
    /// Returns `true` if the identifier was Feed-owned.
    func handleFeedNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        let categoryId = response.notification.request.content.categoryIdentifier
        guard categoryId.hasPrefix("CMUXFeedPermission")
           || categoryId == "CMUXFeedExitPlan"
           || categoryId == "CMUXFeedQuestion"
        else { return false }

        guard let requestId = response.notification.request.content.userInfo["requestId"] as? String else {
            return true
        }

        switch response.actionIdentifier {
        case "feed.permission.once":
            guard let decision = feedPermissionNotificationDecision(requestId: requestId, requestedMode: .once) else {
                return true
            }
            FeedCoordinator.shared.deliverReply(requestId: requestId, decision: decision)
        case "feed.permission.always":
            guard let decision = feedPermissionNotificationDecision(requestId: requestId, requestedMode: .always) else {
                return true
            }
            FeedCoordinator.shared.deliverReply(requestId: requestId, decision: decision)
        case "feed.permission.all":
            guard let decision = feedPermissionNotificationDecision(requestId: requestId, requestedMode: .all) else {
                return true
            }
            FeedCoordinator.shared.deliverReply(requestId: requestId, decision: decision)
        case "feed.permission.deny":
            FeedCoordinator.shared.deliverReply(requestId: requestId, decision: .permission(.deny))
        case "feed.exit_plan.ultraplan":
            FeedCoordinator.shared.deliverReply(requestId: requestId, decision: .exitPlan(.ultraplan))
        case "feed.exit_plan.bypassPermissions":
            FeedCoordinator.shared.deliverReply(requestId: requestId, decision: .exitPlan(.bypassPermissions))
        case "feed.exit_plan.autoAccept":
            FeedCoordinator.shared.deliverReply(requestId: requestId, decision: .exitPlan(.autoAccept))
        case "feed.exit_plan.manual":
            FeedCoordinator.shared.deliverReply(requestId: requestId, decision: .exitPlan(.manual))
        case "feed.question.open":
            // Open the app / focus the Feed sidebar; actual reply happens in-app.
            NSApp.activate(ignoringOtherApps: true)
        case UNNotificationDismissActionIdentifier,
             UNNotificationDefaultActionIdentifier:
            // Tap on the banner body opens the app so user can act in-UI.
            NSApp.activate(ignoringOtherApps: true)
        default:
            break
        }
        return true
    }

    private func feedPermissionNotificationDecision(
        requestId: String,
        requestedMode: WorkstreamPermissionMode
    ) -> WorkstreamDecision? {
        guard let item = FeedCoordinator.shared.snapshot(pendingOnly: false).reversed().first(where: { item in
            guard case .permissionRequest(let itemRequestId, _, _, _) = item.payload else { return false }
            return itemRequestId == requestId
        }) else {
            return .permission(requestedMode)
        }
        guard case .permissionRequest(_, _, let toolInputJSON, _) = item.payload else {
            return .permission(requestedMode)
        }

        switch requestedMode {
        case .once:
            guard FeedPermissionActionPolicy.supportsOncePermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            ) else {
                return nil
            }
            return .permission(.once)
        case .always:
            if FeedPermissionActionPolicy.supportsAlwaysPermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            ) {
                return .permission(.always)
            }
            if FeedPermissionActionPolicy.supportsOncePermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            ) {
                return .permission(.once)
            }
            return nil
        case .all:
            guard FeedPermissionActionPolicy.supportsAllPermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            ) else {
                return nil
            }
            return .permission(.all)
        default:
            return .permission(requestedMode)
        }
    }

}
