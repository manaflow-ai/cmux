public import Foundation
import AppKit

/// Identifiable request to reveal a workspace directory in Finder, used as the
/// `.task(id:)` key on ``TabItemView`` so the reveal is cancellable and tied to
/// the row lifecycle. The app supplies the resolved `directoryURL` (or `nil`,
/// which beeps) through the row's show-in-Finder action.
public struct TabItemFinderDirectoryOpenRequest: Equatable, Sendable {
    public var id = UUID()
    public var directoryURL: URL?

    public init(id: UUID = UUID(), directoryURL: URL?) {
        self.id = id
        self.directoryURL = directoryURL
    }
}

/// Reveals a directory in Finder off the main actor, re-validating existence so
/// a stale path beeps instead of opening the wrong folder. URL-only so the
/// lifted row never references the app-side `Workspace` resolver.
public enum TabItemFinderDirectoryOpener {
    @MainActor
    public static func openInFinder(_ directoryURL: URL?) async {
        guard !Task.isCancelled else { return }
        guard let directoryURL else {
            NSSound.beep()
            return
        }
        if let refreshedURL = await existingDirectoryURL(for: directoryURL.path) {
            guard !Task.isCancelled else { return }
            NSWorkspace.shared.activateFileViewerSelecting([refreshedURL])
        } else {
            guard !Task.isCancelled else { return }
            NSSound.beep()
        }
    }

    private static func existingDirectoryURL(for path: String) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let directoryURL = await Task.detached(priority: .utility) {
            existingDirectoryURLUnchecked(for: path)
        }.value
        guard !Task.isCancelled else { return nil }
        return directoryURL
    }

    private nonisolated static func existingDirectoryURLUnchecked(for path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
