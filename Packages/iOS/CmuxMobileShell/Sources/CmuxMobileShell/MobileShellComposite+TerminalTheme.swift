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
    @discardableResult
    func recordTerminalTheme(_ frame: MobileTerminalRenderGridFrame) -> Bool {
        guard frame.full, let theme = frame.terminalTheme?.validatedOrDefault() else { return false }
        if let currentRevision = terminalThemeState.revisionsBySurfaceID[frame.surfaceID] {
            guard let incomingRevision = frame.terminalThemeRevision,
                  incomingRevision >= currentRevision else { return false }
        }
        let configTheme = frame.terminalConfigTheme?.validatedOrDefault()
        let changed = terminalThemeState.themesBySurfaceID[frame.surfaceID] != theme
            || configTheme.map { terminalThemeState.configThemesBySurfaceID[frame.surfaceID] != $0 } == true
        if let revision = frame.terminalThemeRevision {
            terminalThemeState.revisionsBySurfaceID[frame.surfaceID] = revision
        }
        terminalThemeState.themesBySurfaceID[frame.surfaceID] = theme
        if let configTheme {
            terminalThemeState.configThemesBySurfaceID[frame.surfaceID] = configTheme
        }
        if selectedTerminalID?.rawValue == frame.surfaceID {
            setActiveTerminalThemes(
                chrome: theme,
                config: terminalThemeState.configTheme(for: frame.surfaceID)
            )
        }
        return changed
    }

    func hasCurrentTerminalThemeRevision(_ frame: MobileTerminalRenderGridFrame) -> Bool {
        guard frame.full,
              let currentRevision = terminalThemeState.revisionsBySurfaceID[frame.surfaceID] else {
            return true
        }
        guard let revision = frame.terminalThemeRevision else { return false }
        return revision >= currentRevision
    }

    /// Returns the most recent theme for one surface, falling back to the
    /// connected Mac's host-wide theme before its first full frame arrives.
    func terminalTheme(for surfaceID: String) -> TerminalTheme {
        terminalThemeState.theme(for: surfaceID)
    }

    /// Returns the raw Ghostty defaults for one surface.
    public func terminalConfigTheme(for surfaceID: String) -> TerminalTheme {
        terminalThemeState.configTheme(for: surfaceID)
    }

    func applySelectedTerminalTheme() {
        let surfaceID = selectedTerminalID?.rawValue
        let theme = surfaceID.map(terminalTheme(for:)) ?? terminalThemeState.hostTheme
        let configTheme = surfaceID.map(terminalConfigTheme(for:)) ?? terminalThemeState.hostTheme
        setActiveTerminalThemes(chrome: theme, config: configTheme)
    }

    func resetTerminalThemes() {
        terminalThemeState = MobileTerminalThemeState()
        setActiveTerminalThemes(chrome: .monokai, config: .monokai)
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
        terminalThemeState.configThemesBySurfaceID.removeAll(keepingCapacity: true)
        applySelectedTerminalTheme()
    }

    func pruneTerminalThemes(to workspaces: [MobileWorkspacePreview]) {
        let surfaceIDs = Set(workspaces.flatMap { $0.terminals.map(\.id.rawValue) })
        terminalThemeState.themesBySurfaceID = terminalThemeState.themesBySurfaceID.filter {
            surfaceIDs.contains($0.key)
        }
        terminalThemeState.configThemesBySurfaceID = terminalThemeState.configThemesBySurfaceID.filter {
            surfaceIDs.contains($0.key)
        }
        terminalThemeState.revisionsBySurfaceID = terminalThemeState.revisionsBySurfaceID.filter {
            surfaceIDs.contains($0.key)
        }
    }

    private func setActiveTerminalThemes(chrome: TerminalTheme, config: TerminalTheme) {
        if activeTerminalTheme != chrome {
            activeTerminalTheme = chrome
            terminalThemeGeneration &+= 1
        }
        if activeTerminalConfigTheme != config {
            activeTerminalConfigTheme = config
            terminalConfigThemeGeneration &+= 1
        }
    }

}
