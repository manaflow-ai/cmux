import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppUtilityPanel: Panel {
    let id = UUID()
    let workspaceId: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .appUtility
    let kind: AppUtilityPanelKind
    let settingsNavigationScope = UUID().uuidString

    private(set) var settingsNavigationTarget: SettingsNavigationTarget?
    private(set) var settingsNavigationRevision = 0
    @ObservationIgnored private weak var focusAnchorView: RightSidebarToolFocusAnchorView?

    var displayTitle: String { kind.displayTitle }
    var displayIcon: String? { kind.displayIcon }

    init(
        workspaceId: UUID,
        kind: AppUtilityPanelKind,
        settingsNavigationTarget: SettingsNavigationTarget? = nil
    ) {
        self.workspaceId = workspaceId
        self.kind = kind
        self.settingsNavigationTarget = settingsNavigationTarget
    }

    func requestSettingsNavigation(_ target: SettingsNavigationTarget?) {
        guard kind == .settings, let target else { return }
        settingsNavigationTarget = target
        settingsNavigationRevision &+= 1
    }

    func attachFocusAnchor(_ anchor: RightSidebarToolFocusAnchorView?) {
        focusAnchorView = anchor
    }

    func close() {
        focusAnchorView = nil
    }

    func focus() {
        guard let anchor = focusAnchorView,
              let window = anchor.window else { return }
        _ = window.makeFirstResponder(anchor)
    }

    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) { _ = reason }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        guard focusAnchorView?.ownsKeyboardFocus(responder) == true else { return nil }
        return .panel
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard intent == .panel,
              let responder = window.firstResponder,
              ownedFocusIntent(for: responder, in: window) == intent else {
            return false
        }
        return window.makeFirstResponder(nil)
    }
}
