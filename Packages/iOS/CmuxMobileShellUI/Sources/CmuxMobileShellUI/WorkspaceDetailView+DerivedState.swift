import CmuxMobileShellModel
import CmuxMobileWorkspace
import CoreGraphics

extension WorkspaceDetailView {
    var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == store.selectedTerminalID } ?? workspace.terminals.first
    }

    var selectedTerminalID: String? {
        selectedTerminal?.id.rawValue
    }

    var selectedToolbarSubtitle: String? {
        if let surface = workspace.selectedMacSurface(id: store.selectedMacSurfaceID) {
            return surface.title
        }
        guard let selectedTerminalID = store.selectedTerminalID else { return nil }
        return workspace.terminals.first { $0.id == selectedTerminalID }?.name
    }

    var terminalTopPadding: CGFloat { 4 }

    /// Whether the terminal renders the scroll-edge band: the surface
    /// extends under the (glass) navigation bar and fills that region with
    /// render-only scrollback overscan rows, so the iOS 26 scroll edge
    /// effect has live content to blur. Pre-26 keeps the opaque bar and the
    /// below-bar layout.
    var terminalScrollEdgeBandEnabled: Bool {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return false }
        return true
        #else
        return false
        #endif
    }

    /// The top band handed to the terminal surface: the captured safe-area
    /// inset plus the small seam the grid keeps below the bar (the same
    /// clearance `terminalTopPadding` provided when the grid started below
    /// the bar).
    var terminalSurfaceTopContentInset: CGFloat {
        guard terminalScrollEdgeBandEnabled else { return 0 }
        return terminalCapturedTopInset + terminalTopPadding
    }

    /// Whether the navigation bar shows the scroll-edge treatment right now:
    /// the band is supported and the terminal is the visible surface (the
    /// opacity-swapped siblings keep the opaque bar).
    var terminalScrollEdgeGlassActive: Bool {
        terminalScrollEdgeBandEnabled && activeSurface == .terminal
    }

    /// iOS renders the workspace title as a custom principal toolbar item. Keep
    /// the system title empty there so it does not draw a second centered title.
    var systemNavigationTitle: String {
        #if os(iOS)
        ""
        #else
        workspace.name
        #endif
    }

}
