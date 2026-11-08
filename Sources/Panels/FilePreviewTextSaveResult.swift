import Foundation

/// The bounded result of saving editable local preview text.
enum FilePreviewTextSaveResult: Sendable {
    case saved
    case failed(fileExists: Bool)
}
