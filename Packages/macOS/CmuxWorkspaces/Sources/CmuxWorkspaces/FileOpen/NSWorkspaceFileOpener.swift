public import Foundation
internal import AppKit

/// The production ``SystemFileOpening`` conformer: opens files through
/// `NSWorkspace`, exactly like the legacy `PreferredEditorSettings`
/// fallback path.
public struct NSWorkspaceFileOpener: SystemFileOpening {
    /// Creates an opener backed by the shared `NSWorkspace`.
    public init() {}

    @MainActor
    public func openWithSystemDefault(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
