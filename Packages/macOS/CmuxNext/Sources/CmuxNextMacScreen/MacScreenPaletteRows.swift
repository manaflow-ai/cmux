public import CmuxNextActions
import CmuxNextDevices
public import CmuxNextPalette

/// One root palette row per device Screen Sharing lists ("Screen Sharing: air-blue"), so typing a
/// machine's name opens its screen in one step instead of opening Screen Sharing and then choosing it.
/// A row runs `macScreen.open` with that device, the action the Screen Sharing page and the CLI
/// (`cmux tab new-mac-screen --device`) run; the hub still asks the host and owns the session.
@MainActor
public enum MacScreenPaletteRows {
    static let providerID = "macScreen.devices"
    static let action: ActionID = "macScreen.open"

    /// The root provider: the signed-in hub's devices, read on each open; none for the empty query.
    public static func provider(pages: MacScreenPages, registry: ActionRegistry) -> AsyncPaletteProvider {
        AsyncPaletteProvider(id: providerID, showsItemsForEmptyQuery: false) { [weak pages, weak registry] in
            guard let pages, let registry, registry.isAvailable(action) else { return [] }
            return rows(devices: pages.viewableDevices, actionTitle: registry.title(for: action)) { [weak registry] in
                _ = registry?.perform(action, invocation: $0)
            }
        }
    }

    /// The rows for `devices`, titled by the action ("Screen Sharing: air-blue"); `perform` runs the open.
    static func rows(devices: [HubDevice], actionTitle: String?, perform: @escaping @MainActor (ActionInvocation) -> Void) -> [PaletteItem] {
        guard let actionTitle, !actionTitle.isEmpty else { return [] }
        let connect = L.t("macScreen.toolbar.connect", "Connect")
        return devices.filter { !$0.name.isEmpty }.map { device in
            PaletteItem(
                id: "\(providerID):\(device.id)",
                title: "\(actionTitle): \(device.name)",
                symbol: device.platform == .ios ? "iphone" : "display",
                keywords: [device.name, "screen sharing", "screen share", "share screen", "remote desktop", "vnc", "view", "device", "machine"],
                primary: PaletteCommand(id: "open", title: connect, symbol: "return", effect: .perform {
                    perform(ActionInvocation(arguments: ["device": .string(device.id)], origin: .user))
                }),
                frecencyKey: "\(providerID):\(device.id)"
            )
        }
    }
}
