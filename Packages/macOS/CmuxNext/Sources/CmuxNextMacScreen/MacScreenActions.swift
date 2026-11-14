public import CmuxNextActions
import CmuxNextDaemonService
import Foundation

/// AppKit bindings shared by menus, the palette and CLI. The app supplies only tab placement
/// and identity lookup; the existing hub remains the owner of authorization and disconnect.
public struct MacScreenActions {
    let pages: MacScreenPages
    let selectedTab: () -> String?
    let providerKey: (String, String?) -> String?
    let open: (() throws -> MacScreenRecord, ActionInvocation, Bool) throws -> Void
    let refusal: (any Error) -> Void

    public init(pages: MacScreenPages, selectedTab: @escaping () -> String?,
                providerKey: @escaping (String, String?) -> String?,
                open: @escaping (() throws -> MacScreenRecord, ActionInvocation, Bool) throws -> Void,
                refusal: @escaping (any Error) -> Void) {
        self.pages = pages
        self.selectedTab = selectedTab
        self.providerKey = providerKey
        self.open = open
        self.refusal = refusal
    }

    public func bind(into registry: ActionRegistry) {
        registry.bindEffect("macScreen.open", effect: { invocation in
            if let target = invocation.target, target.kind != .pane && target.kind != .tab { return .refused(Self.noPane) }
            do { try open({ try Self.record(invocation, pages: pages) }, invocation, Self.isPerson(invocation)) }
            catch { refusal(error) }
            return .done
        })
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

    static func record(_ invocation: ActionInvocation, pages: MacScreenPages) throws -> MacScreenRecord {
        guard let value = invocation["device"] else { return MacScreenRecord(macID: nil) }
        guard let device = value.stringValue, MacScreenRecord(deviceID: device).deviceID != nil else {
            throw ActionFailure(message: invalidDevice)
        }
        return pages.record(forDevice: device, requesting: isPerson(invocation) ? .view : nil)
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
              let phase = pane.model.hub?.phase, phase.isPending || phase.streamingScope != nil else { return nil }
        return pane
    }

    private static func isPerson(_ invocation: ActionInvocation) -> Bool {
        invocation.origin == .user && !invocation.viaControlSocket && ActionRunScope.isPersonsAction()
    }
    private static var noPane: String { L.t("macScreen.actions.noPane", "Choose a pane or tab to open Screen Sharing.") }
    private static var noViewer: String { L.t("macScreen.actions.noViewer", "Choose a Screen Sharing tab to stop viewing.") }
    private static var invalidDevice: String { L.t("macScreen.actions.invalidDevice", "Choose a device from Screen Sharing.") }
}
