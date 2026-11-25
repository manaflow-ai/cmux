public import CmuxNextActions
public import CmuxNextDevices
public import CmuxNextPalette

/// One root palette row per device Screen Sharing lists ("Screen Sharing: Studio"), so typing a
/// machine's name opens its screen in one step instead of opening Screen Sharing and then choosing it.
/// A row runs `macScreen.open` with that device, the action the Screen Sharing page and the CLI
/// (`cmux tab new-mac-screen --device NAME [--scope view|full]`) run; the hub still asks the host and owns the session.
extension MacScreenPages {
    static let paletteProviderID = "macScreen.devices"
    static let paletteAction: ActionID = "macScreen.open"

    /// The devices Screen Sharing lists to view, as its home page lists them; empty while signed out.
    public var viewableDevices: [HubDevice] {
        hub.map { MacScreenHomeSnapshot.listed($0.otherDevices) } ?? []
    }

    /// The root provider: the signed-in hub's devices, read on each open; none for the empty query.
    public func paletteProvider(registry: ActionRegistry) -> AsyncPaletteProvider {
        let action = Self.paletteAction
        return AsyncPaletteProvider(id: Self.paletteProviderID, showsItemsForEmptyQuery: false) { [weak self, weak registry] in
            guard let self, let registry, registry.isAvailable(action) else { return [] }
            return Self.paletteRows(devices: viewableDevices, actionTitle: registry.title(for: action)) { [weak registry] in
                _ = registry?.perform(action, invocation: $0)
            }
        }
    }

    /// The rows for `devices`, titled by the action ("Screen Sharing: Studio"); `perform` runs the open.
    static func paletteRows(devices: [HubDevice], actionTitle: String?,
                            perform: @escaping @MainActor (ActionInvocation) -> Void) -> [PaletteItem] {
        guard let actionTitle, !actionTitle.isEmpty else { return [] }
        let connect = L.t("macScreen.toolbar.connect", "Connect")
        // A Windows PC is listed on the page ("Can’t view yet") but has no screen to open from here yet.
        return devices.filter { !$0.name.isEmpty && $0.platform != .windows }.map { device in
            PaletteItem(
                id: "\(paletteProviderID):\(device.id)",
                title: "\(actionTitle): \(device.name)",
                symbol: MacScreenHomeView.glyph(device.platform ?? .macos),
                keywords: [device.name, "screen sharing", "screen share", "share screen", "remote desktop", "vnc", "view", "device", "machine"],
                primary: PaletteCommand(id: "open", title: connect, symbol: "return", effect: .perform {
                    perform(ActionInvocation(arguments: ["device": .string(device.id)], origin: .user))
                }),
                frecencyKey: "\(paletteProviderID):\(device.id)"
            )
        }
    }
}
