import Foundation

/// The result of placing a browser to the right of a source surface.
@MainActor
struct BrowserSplitPlacement {
    let surfaceID: UUID
    let panel: BrowserPanel?
    let createdSplit: Bool

    init?(
        outcome: BrowserPanelCreationOutcome,
        createdSplit: Bool
    ) {
        guard let surfaceID = outcome.surfaceID else { return nil }
        self.surfaceID = surfaceID
        self.panel = outcome.panel
        self.createdSplit = createdSplit
    }
}
