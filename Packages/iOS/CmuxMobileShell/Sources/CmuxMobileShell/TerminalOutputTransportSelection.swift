import Foundation

func resolvedTerminalOutputTransport(
    capabilities: Set<String>,
    terminalFidelity: String?
) -> MobileShellComposite.TerminalOutputTransport {
    let supportsRenderGrid = capabilities.contains("terminal.render_grid.v1")
        || terminalFidelity == "render_grid"
    let supportsTerminalBytes = capabilities.contains("terminal.bytes.v1")
    let supportsVerifiedReplay = capabilities.contains("terminal.render_grid.verified_replay.v1")
    if supportsVerifiedReplay {
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

func fallbackTerminalOutputTransport(
    learnedCapabilities: Set<String>
) -> MobileShellComposite.TerminalOutputTransport {
    resolvedTerminalOutputTransport(
        capabilities: learnedCapabilities,
        terminalFidelity: nil
    )
}

func guardedFallbackTerminalOutputTransport(
    learnedCapabilities: Set<String>,
    isCurrentClient: Bool
) -> MobileShellComposite.TerminalOutputTransport? {
    guard isCurrentClient else { return nil }
    return fallbackTerminalOutputTransport(
        learnedCapabilities: learnedCapabilities
    )
}
