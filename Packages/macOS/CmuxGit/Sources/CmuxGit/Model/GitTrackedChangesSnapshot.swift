import Foundation

/// The working-tree dirty result and index signatures from one tracked scan.
struct GitTrackedChangesSnapshot: Equatable, Sendable {
    let isDirty: Bool
    let indexSignature: String?
    let indexContentSignature: String?
}
