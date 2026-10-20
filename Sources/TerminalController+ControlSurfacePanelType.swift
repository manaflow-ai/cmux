import Foundation

extension TerminalController {
    /// Maps the coordinator's raw token through the shared control API parser.
    func surfacePanelType(forRawToken raw: String) -> PanelType? {
        v2PanelType(rawToken: raw)
    }
}
