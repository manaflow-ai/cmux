import CmuxArtifacts
import Foundation

/// Immutable row data passed below the SwiftUI list boundary.
struct ArtifactPaneRowSnapshot: Identifiable, Equatable {
    let record: ArtifactRecord
    let ownerTitle: String?
    let displayValue: String
    let detail: String
    let snippet: String?

    var id: UUID { record.id }
}
