public import CmuxNextActions
public import CmuxNextPalette

extension AgentChatDestinations {
    /// The New Agent Chat picker's host list (`palette.newAgentChat`, `palette.newAgentChatOn`): this Mac at once,
    /// then the peers and cloud machines as they are listed.
    ///
    /// A slow acpmux never holds the picker: past the bound it shows "Other Macs not loaded yet", then the
    /// peers when acpmux lists them (``updates(peerBound:)``).
    ///
    /// - Parameter next: The source for every other target kind.
    /// - Returns: A source that answers the two actions' machine targets and forwards the rest to `next`.
    @MainActor
    public func paletteTargets(next: any PaletteTargetSource) -> any PaletteTargetSource {
        // A link on its way is listed like a connected one (``Destination/isOnItsWay``).
        func option(_ row: Destination) -> PaletteTargetOption {
            PaletteTargetOption(id: row.id, title: row.title, subtitle: row.isOnItsWay ? nil : row.state, symbol: row.symbol,
                                isEnabled: row.opens)
        }
        return RefreshingPaletteTargetSource(kind: .machine, actions: ["palette.newAgentChat", "palette.newAgentChatOn"],
            initial: [option(local)], next: next, updates: { self.updates() }, option: option)
    }
}
