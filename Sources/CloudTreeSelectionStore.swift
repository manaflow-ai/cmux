import Foundation

/// Owns the authoritative Cloud tree selection for one main window.
@MainActor
final class CloudTreeSelectionStore {
    var value: CloudTreeSelection = .empty
}
