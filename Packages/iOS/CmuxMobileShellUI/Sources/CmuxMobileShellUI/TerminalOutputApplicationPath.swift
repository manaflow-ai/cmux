import CmuxMobileShellModel
import Foundation

enum TerminalOutputApplicationPath: Equatable {
    case verifiedReplay
    case rejectUnverified
    case legacy
}

func terminalOutputApplicationPath(
    for chunk: MobileTerminalOutputChunk,
    expectedSurfaceID: String
) -> TerminalOutputApplicationPath {
    // A view owns exactly one terminal. Output naming any other terminal is
    // never drawn, on any path; rejecting it resyncs this view.
    if let surfaceID = chunk.surfaceID, !sameTerminal(surfaceID, expectedSurfaceID) {
        return .rejectUnverified
    }
    if let frame = chunk.sourceRenderGridFrame, !sameTerminal(frame.surfaceID, expectedSurfaceID) {
        return .rejectUnverified
    }
    guard chunk.requiresVerifiedReplay else { return .legacy }

    if let frame = chunk.sourceRenderGridFrame {
        guard !frame.renderEpoch.isEmpty,
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

private func sameTerminal(_ lhs: String, _ rhs: String) -> Bool {
    lhs.caseInsensitiveCompare(rhs) == .orderedSame
}
