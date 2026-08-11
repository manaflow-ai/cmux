import CmuxMobileShellModel

enum TerminalOutputApplicationPath: Equatable {
    case verifiedReplay
    case rejectUnverified
    case viewportPreservingDelta
    case legacy
}

func terminalOutputApplicationPath(
    for chunk: MobileTerminalOutputChunk,
    expectedSurfaceID: String
) -> TerminalOutputApplicationPath {
    guard chunk.requiresVerifiedReplay else {
        if let frame = chunk.sourceRenderGridFrame,
           frame.surfaceID == expectedSurfaceID,
           !frame.full,
           frame.anchor == .screen,
           frame.activeScreen == .primary {
            return .viewportPreservingDelta
        }
        return .legacy
    }

    if let frame = chunk.sourceRenderGridFrame {
        guard frame.surfaceID == expectedSurfaceID,
              !frame.renderEpoch.isEmpty,
              frame.renderRevision > 0 else {
            return .rejectUnverified
        }
        return .verifiedReplay
    }
    if !chunk.data.isEmpty {
        return .rejectUnverified
    }
    return .legacy
}
