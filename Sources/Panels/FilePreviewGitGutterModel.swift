import CmuxFilePreviewCore
import Observation

/// The git gutter markers a File Preview panel shows.
///
/// The panel's view reads ``markers`` and ``revision`` and hands them to the
/// editor as values, so the editor only repaints the gutter when the revision
/// advances instead of comparing marker sets on every keystroke.
@MainActor
@Observable
final class FilePreviewGitGutterModel {
    private(set) var markers = FilePreviewGitGutterMarkers.untracked
    private(set) var revision = 0

    func publish(_ next: FilePreviewGitGutterMarkers) {
        guard next != markers else { return }
        markers = next
        revision += 1
    }
}
