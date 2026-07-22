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
        if supportsVerifiedReplay, supportsRenderGrid {
            return .renderGrid
        }
        if supportsRenderGrid, supportsTerminalBytes {
            return .hybrid
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
