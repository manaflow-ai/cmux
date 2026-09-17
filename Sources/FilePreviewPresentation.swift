import Foundation

/// Presentation behavior for a file-preview panel.
enum FilePreviewPresentation: Equatable, Sendable {
    case file
    case note(title: String)

    var displayTitle: String? {
        guard case .note(let title) = self else { return nil }
        return title
    }

    var hidesFileHeader: Bool {
        if case .note = self { return true }
        return false
    }

    var autosavesTextChanges: Bool {
        if case .note = self { return true }
        return false
    }

    var noteTitle: String? {
        guard case .note(let title) = self else { return nil }
        return title
    }
}
