import Foundation

extension MobileShellComposite {
    nonisolated static func resolvedTerminalOutputTransport(
        capabilities: Set<String>,
        terminalFidelity: String?
    ) -> TerminalOutputTransport {
        let supportsRenderGrid = capabilities.contains("terminal.render_grid.v1")
            || terminalFidelity == "render_grid"
        let supportsTerminalBytes = capabilities.contains("terminal.bytes.v1")
        let supportsVerifiedReplay = capabilities.contains("terminal.render_grid.verified_replay.v1")
        let supportsScreenAnchor = capabilities.contains("terminal.render_grid.screen_anchor.v1")
        // Screen-anchored frames maintain the phone's local scrollback and
        // enable pixel-precise primary-screen scrolling. Hybrid delivery does
        // not negotiate that anchor, so selecting it here would fall back to
        // whole-row scrolling and forward every gesture to the Mac.
        if supportsRenderGrid, supportsScreenAnchor {
            return .renderGrid
        }
        // Hosts without screen anchors keep the dedicated terminal lane:
        // their render-grid applies can wait on a replay fence while a
        // keyboard resize is in flight; raw bytes have no such dependency.
        if supportsRenderGrid, supportsTerminalBytes {
            return .hybrid
        }
        if supportsVerifiedReplay, supportsRenderGrid {
            return .renderGrid
        }
        if supportsRenderGrid {
            return .renderGrid
        }
        return .rawBytes
    }

    nonisolated static func fallbackTerminalOutputTransport(
        learnedCapabilities: Set<String>
    ) -> TerminalOutputTransport {
        resolvedTerminalOutputTransport(
            capabilities: learnedCapabilities,
            terminalFidelity: nil
        )
    }

    nonisolated static func guardedFallbackTerminalOutputTransport(
        learnedCapabilities: Set<String>,
        isCurrentClient: Bool
    ) -> TerminalOutputTransport? {
        guard isCurrentClient else { return nil }
        return fallbackTerminalOutputTransport(
            learnedCapabilities: learnedCapabilities
        )
    }
}
