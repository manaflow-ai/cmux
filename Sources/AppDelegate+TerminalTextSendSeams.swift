import AppKit
import Combine
import CmuxNotifications
import CmuxTerminal
import Foundation

/// App-side ``TerminalTextSendPanel`` conformer over a `TerminalPanel`. Forwards
/// each member to the underlying panel, matching the exact reads the legacy
/// `sendTextWhenReady` performed (`isAgentHibernated`, `surface.surface != nil`,
/// `surface.requestInputDemandSurfaceStartIfNeeded()`, `sendText(_:)`).
@MainActor
final class TerminalTextSendPanelAdapter: TerminalTextSendPanel {
    private let panel: TerminalPanel

    init(_ panel: TerminalPanel) {
        self.panel = panel
    }

    var panelID: UUID { panel.id }

    var isAgentHibernated: Bool { panel.isAgentHibernated }

    var isSurfaceReady: Bool { panel.surface.surface != nil }

    func requestInputDemandSurfaceStartIfNeeded() {
        panel.surface.requestInputDemandSurfaceStartIfNeeded()
    }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        panel.sendText(text)
    }
}

/// App-side ``TerminalTextSendTarget`` conformer over a `Workspace`/`Tab`. Wraps
/// the platform primitives the readiness orchestration is built on: panel
/// resolution (`AppDelegate.resolveTerminalPanelForTextSend`), the Combine
/// `panelsPublisher`, the ghostty `NotificationCenter` readiness signals, and the
/// `DispatchQueue.main.asyncAfter` timeout. Each observer/timeout is returned as
/// a ``TerminalTextSendObserverToken`` so the coordinator tears them down without
/// knowing the backing mechanism.
@MainActor
final class TerminalTextSendTargetAdapter: TerminalTextSendTarget {
    private let tab: Tab

    init(_ tab: Tab) {
        self.tab = tab
    }

    var workspaceID: UUID { tab.id }

    func resolveSendPanel(preferredPanelID: UUID?) -> (any TerminalTextSendPanel)? {
        guard let panel = AppDelegate.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelID
        ) else { return nil }
        return TerminalTextSendPanelAdapter(panel)
    }

    func observePanelsChanged(_ handler: @escaping @MainActor () -> Void) -> any TerminalTextSendCancellable {
        let cancellable = tab.panelsPublisher
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in handler() }
            }
        return TerminalTextSendObserverToken { cancellable.cancel() }
    }

    func observeSurfaceReady(_ handler: @escaping @MainActor (UUID?) -> Void) -> any TerminalTextSendCancellable {
        let workspaceID = tab.id
        let observer = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let noteWorkspaceId = note.userInfo?["workspaceId"] as? UUID,
                  noteWorkspaceId == workspaceID else { return }
            let surfaceId = note.userInfo?["surfaceId"] as? UUID
            Task { @MainActor in handler(surfaceId) }
        }
        return TerminalTextSendObserverToken {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func observeDidFocusSurface(_ handler: @escaping @MainActor (UUID) -> Void) -> any TerminalTextSendCancellable {
        let workspaceID = tab.id
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  candidateTabId == workspaceID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                return
            }
            Task { @MainActor in handler(candidateSurfaceId) }
        }
        return TerminalTextSendObserverToken {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func observeDidBecomeFirstResponderSurface(_ handler: @escaping @MainActor (UUID) -> Void) -> any TerminalTextSendCancellable {
        let workspaceID = tab.id
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  candidateTabId == workspaceID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                return
            }
            Task { @MainActor in handler(candidateSurfaceId) }
        }
        return TerminalTextSendObserverToken {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func scheduleTimeout(after seconds: TimeInterval, _ handler: @escaping @MainActor () -> Void) -> any TerminalTextSendCancellable {
        let work = DispatchWorkItem {
            handler()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return TerminalTextSendObserverToken { work.cancel() }
    }
}
