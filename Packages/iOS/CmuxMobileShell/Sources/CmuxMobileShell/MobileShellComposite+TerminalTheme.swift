public import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    /// Applies the host-wide theme reported during connection negotiation.
    /// - Parameter theme: The Mac's resolved theme, or `nil` for a legacy host.
    public func applyTerminalTheme(_ theme: TerminalTheme?) {
        terminalThemeState.hostTheme = theme?.validatedOrDefault() ?? .monokai
        applySelectedTerminalTheme()
    }

    /// Records a full render-grid frame's theme for its surface and updates the
    /// active chrome when that surface is selected.
    func recordTerminalTheme(_ frame: MobileTerminalRenderGridFrame) {
        guard frame.full, let theme = frame.terminalTheme?.validatedOrDefault() else { return }
        if let currentRevision = terminalThemeState.revisionsBySurfaceID[frame.surfaceID] {
            guard let incomingRevision = frame.terminalThemeRevision,
                  incomingRevision >= currentRevision else { return }
        }
        if let revision = frame.terminalThemeRevision {
            terminalThemeState.revisionsBySurfaceID[frame.surfaceID] = revision
        }
        terminalThemeState.themesBySurfaceID[frame.surfaceID] = theme
        if selectedTerminalID?.rawValue == frame.surfaceID {
            setActiveTerminalTheme(theme)
        }
    }

    /// Returns the most recent theme for one surface, falling back to the
    /// connected Mac's host-wide theme before its first full frame arrives.
    func terminalTheme(for surfaceID: String) -> TerminalTheme {
        terminalThemeState.theme(for: surfaceID)
    }

    func applySelectedTerminalTheme() {
        let theme = selectedTerminalID.map { terminalTheme(for: $0.rawValue) }
            ?? terminalThemeState.hostTheme
        setActiveTerminalTheme(theme)
    }

    func resetTerminalThemes() {
        terminalThemeState = MobileTerminalThemeState()
    }

    func prepareTerminalThemeRevisionAuthority(
        macInstanceTag: String?,
        producerEpoch: String?,
        connectionID: String
    ) {
        let normalizedTag = macInstanceTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEpoch = producerEpoch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = normalizedTag.flatMap { $0.isEmpty ? nil : $0 }
        let epoch = normalizedEpoch.flatMap { $0.isEmpty ? nil : $0 }
        let authority = epoch.map { "producer:\(tag ?? "unknown"):\($0)" }
            ?? "connection:\(connectionID)"
        guard terminalThemeState.revisionAuthority != authority else { return }
        terminalThemeState.revisionAuthority = authority
        terminalThemeState.revisionsBySurfaceID.removeAll(keepingCapacity: true)
        terminalThemeState.themesBySurfaceID.removeAll(keepingCapacity: true)
        applySelectedTerminalTheme()
    }

    func pruneTerminalThemes(to workspaces: [MobileWorkspacePreview]) {
        let surfaceIDs = Set(workspaces.flatMap { $0.terminals.map(\.id.rawValue) })
        terminalThemeState.themesBySurfaceID = terminalThemeState.themesBySurfaceID.filter {
            surfaceIDs.contains($0.key)
        }
        terminalThemeState.revisionsBySurfaceID = terminalThemeState.revisionsBySurfaceID.filter {
            surfaceIDs.contains($0.key)
        }
    }

    private func setActiveTerminalTheme(_ theme: TerminalTheme) {
        guard terminalThemeState.activeTheme != theme else { return }
        terminalThemeState.activeTheme = theme
        terminalThemeState.generation &+= 1
    }

    #if DEBUG
    /// Feeds a full render-grid frame into the production per-surface theme
    /// recorder for simulator artifact tests. This symbol is absent in release
    /// builds; production frames reach the same recorder through terminal output
    /// delivery.
    public func debugRecordTerminalTheme(from frame: MobileTerminalRenderGridFrame) {
        recordTerminalTheme(frame)
    }
    #endif
}
