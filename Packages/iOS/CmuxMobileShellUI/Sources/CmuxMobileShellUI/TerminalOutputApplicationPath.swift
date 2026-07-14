import CmuxMobileShellModel

enum TerminalOutputApplicationPath: Equatable {
    case verifiedReplay
    case rejectUnverified
    case legacy
}

func terminalOutputApplicationPath(
    for chunk: MobileTerminalOutputChunk
) -> TerminalOutputApplicationPath {
    if let frame = chunk.sourceRenderGridFrame,
       !frame.renderEpoch.isEmpty,
       frame.renderRevision > 0 {
        return .verifiedReplay
    }
    if chunk.requiresVerifiedReplay, !chunk.data.isEmpty {
        return .rejectUnverified
    }
    return .legacy
}
