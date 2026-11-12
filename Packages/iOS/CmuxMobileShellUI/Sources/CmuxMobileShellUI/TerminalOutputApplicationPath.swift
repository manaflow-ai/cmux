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
    let named = [chunk.surfaceID, chunk.sourceRenderGridFrame?.surfaceID].compactMap { $0 }
    if named.contains(where: { $0.caseInsensitiveCompare(expectedSurfaceID) != .orderedSame }) {
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
