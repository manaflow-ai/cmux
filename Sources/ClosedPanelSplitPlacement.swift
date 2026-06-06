import Bonsplit
import Foundation

struct ClosedPanelSplitPlacement: Codable {
    let orientation: SplitOrientation
    let insertFirst: Bool
    let anchorPanelId: UUID?
}
