import Foundation

/// A stable browser panel identity that retains which split container owns it.
nonisolated struct BrowserActionTarget: Equatable, Sendable {
    let host: PanelHost
    let panelId: UUID
}
