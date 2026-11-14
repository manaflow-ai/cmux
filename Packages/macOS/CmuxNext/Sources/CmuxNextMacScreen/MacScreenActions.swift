public import CmuxNextActions
import Foundation

/// AppKit bindings shared by menus, the palette and CLI. The app supplies only tab identity
/// lookup; the existing hub remains the owner of authorization and disconnect. (#42804 adds
/// `macScreen.open` with a device here.)
public struct MacScreenActions {
    let pages: MacScreenPages
    let selectedTab: () -> String?
    let providerKey: (String, String?) -> String?

    public init(pages: MacScreenPages, selectedTab: @escaping () -> String?,
                providerKey: @escaping (String, String?) -> String?) {
        self.pages = pages
        self.selectedTab = selectedTab
        self.providerKey = providerKey
    }

    public func bind(into registry: ActionRegistry) {
        registry.bindEffect("macScreen.stopViewing", effect: { invocation in
            guard let viewer = viewer(invocation) else { return .refused(Self.noViewer) }
            viewer.disconnectByPerson()
            return .done
        })
        ActionTargetVisibility.gate("macScreen.stopViewing", in: registry) { viewer($0) == nil ? Self.noViewer : nil }
        registry.bindEffect("macScreen.stopSharing", unavailable: { pages.hubHost.noSessionReason }, effect: { _ in
            _ = pages.hubHost.stopSession()
            return .done
        })
        registry.bindEffect("macScreen.revokeViewer", unavailable: { pages.hubHost.noSessionReason }, effect: { _ in
            _ = pages.hubHost.revokeViewer()
            return .done
        })
    }

    func viewer(_ invocation: ActionInvocation) -> MacScreenPane? {
        let id: String
        if let target = invocation.target ?? invocation["tab"]?.targetValue {
            guard target.kind == .tab else { return nil }
            id = target.id
        } else {
            guard let selected = selectedTab() else { return nil }
            id = selected
        }
        guard let key = providerKey(id, invocation.targetMachineID), let pane = pages.tab(key)?.pane,
              pane.model.hub != nil else { return nil }
        return pane
    }

    private static var noViewer: String { L.t("macScreen.actions.noViewer", "Choose a Screen Sharing tab to stop viewing.") }
}
