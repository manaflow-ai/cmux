import Foundation

extension TerminalPanel {
    func readSurfaceSelection() async -> SurfaceSelectionReadResult {
        switch await surface.readSelection(
            maxBytes: SurfaceSelectionSnapshot.maximumTextBytes
        ) {
        case .none:
            return .snapshot(.none(kind: .terminal))
        case .selected(let text):
            return .snapshot(.selected(
                kind: .terminal,
                text: SurfaceSelectionSnapshot.boundedText(text)
            ))
        case .unavailable:
            return .unavailable
        }
    }
}
