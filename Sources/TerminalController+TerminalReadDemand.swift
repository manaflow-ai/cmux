import Foundation

extension TerminalController {
    func ensureTerminalSurfaceReadyForRead(
        _ terminalPanel: TerminalPanel,
        reason: String,
        startIfNeeded: Bool = false
    ) -> Bool {
        let surface = terminalPanel.surface
        if surface.liveSurfaceForGhosttyAccess(reason: "\(reason).preflight") != nil {
            return true
        }
        guard startIfNeeded else {
            return false
        }
        surface.requestReadDemandSurfaceStartIfNeeded()
        return surface.liveSurfaceForGhosttyAccess(reason: "\(reason).readDemand") != nil
    }

    func readTerminalTextBase64(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil,
        startIfNeeded: Bool = false
    ) -> String {
        guard ensureTerminalSurfaceReadyForRead(
                terminalPanel,
                reason: "readTerminalTextBase64",
                startIfNeeded: startIfNeeded
              ),
              let snapshot = readTerminalTextRawSnapshot(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback
              ) else {
            return "ERROR: Terminal surface not found"
        }
        switch Self.terminalTextPayload(
            from: snapshot,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) {
        case .success(let payload):
            return "OK \(payload.base64)"
        case .failure(let error):
            return "ERROR: \(error.message)"
        }
    }
}
