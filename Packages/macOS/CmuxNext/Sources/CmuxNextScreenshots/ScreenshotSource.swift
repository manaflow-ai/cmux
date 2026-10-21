import CmuxNextFileGrid
public import Foundation

/// One folder the Screenshots pane lists, with the rule for which of its
/// files are screenshots and recordings.
public nonisolated struct ScreenshotSource: Sendable, Hashable, Identifiable {
    /// Stable id: `system`, `system.preview`, `tool.<tool>`, `tool.<tool>.history`, `custom.<path>`.
    public var id: String
    /// What the source menu shows.
    public var label: String
    /// The folder.
    public var folder: URL
    /// Where it came from.
    public var origin: ScreenshotSourceOrigin
    /// Which files it lists.
    public var rule: ScreenshotScanRule

    /// Makes a source.
    ///
    /// - Parameters:
    ///   - id: stable id.
    ///   - label: menu label.
    ///   - folder: the folder.
    ///   - origin: where it came from.
    ///   - rule: which files it lists.
    public init(id: String, label: String, folder: URL, origin: ScreenshotSourceOrigin, rule: ScreenshotScanRule) {
        self.id = id
        self.label = label
        self.folder = folder
        self.origin = origin
        self.rule = rule
    }

    /// Whether files dropped on the pane may be saved here: the macOS screenshot folder and the
    /// person's own folders, never an app's private history or the preview folder.
    public var acceptsDrops: Bool {
        switch origin {
        case .system, .custom, .tool: true
        case .systemPreview, .toolHistory: false
        }
    }
}
