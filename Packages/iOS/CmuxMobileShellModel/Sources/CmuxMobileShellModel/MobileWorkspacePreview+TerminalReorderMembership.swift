extension MobileWorkspacePreview {
    /// Whether pane membership provides one unambiguous host index for every
    /// visible terminal. Older flat payloads use the unique terminal list as
    /// their compatibility pane and are coherent without explicit membership.
    public var hasCoherentTerminalReorderMembership: Bool {
        let terminalIDs = terminals.map(\.id)
        guard Set(terminalIDs).count == terminalIDs.count else { return false }
        guard !panes.isEmpty else {
            return terminals.allSatisfy { $0.paneID == nil }
        }

        let paneIDs = panes.map(\.id)
        guard Set(paneIDs).count == paneIDs.count else { return false }

        let terminalsByID = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, $0) })
        var assignedTerminalIDs: Set<MobileTerminalPreview.ID> = []
        for pane in panes {
            for terminalID in pane.terminalIDs {
                guard let terminal = terminalsByID[terminalID],
                      assignedTerminalIDs.insert(terminalID).inserted,
                      terminal.paneID == nil || terminal.paneID == pane.id else {
                    return false
                }
            }
        }
        return assignedTerminalIDs == Set(terminalIDs)
    }
}
