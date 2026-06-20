#if canImport(AppKit)
#if DEBUG

public import Foundation

/// One selectable row in the ``FileExplorerStyleDebugView`` style list.
///
/// The file-explorer style enum (`FileExplorerStyle`) lives in the app target,
/// where it carries the production layout metrics the running outline view reads.
/// The debug panel only needs each style's identity, its human-readable label and
/// description, and the three metrics it echoes back to the user, so the app
/// snapshots every style into one of these value rows and injects the ordered list
/// through ``DebugWindowsCoordinator``'s `fileExplorerStyleDebugContentProvider`.
/// The package view therefore holds no reference to the app-target enum.
///
/// `rawValue` is the byte-identical `fileExplorer.style` `UserDefaults` integer the
/// panel writes when a row is picked, matching the legacy app-side `@AppStorage`
/// contract exactly.
public struct FileExplorerStyleDebugOption: Identifiable, Sendable {
    /// The `fileExplorer.style` raw integer this row selects.
    public var rawValue: Int

    /// The style's display name (`FileExplorerStyle.label`).
    public var label: String

    /// The one-line description shown under the label (the legacy in-view
    /// `styleDescription(_:)` text).
    public var description: String

    /// The style's outline-row height in points (`FileExplorerStyle.rowHeight`).
    public var rowHeight: CGFloat

    /// The style's child indentation in points (`FileExplorerStyle.indentation`).
    public var indentation: CGFloat

    /// The style's icon size in points (`FileExplorerStyle.iconSize`).
    public var iconSize: CGFloat

    /// Stable identity for `ForEach`, keyed on the persisted raw value (matching the
    /// legacy `ForEach(FileExplorerStyle.allCases, id: \.rawValue)`).
    public var id: Int { rawValue }

    /// Creates a snapshot of one app-target file-explorer style.
    public init(
        rawValue: Int,
        label: String,
        description: String,
        rowHeight: CGFloat,
        indentation: CGFloat,
        iconSize: CGFloat
    ) {
        self.rawValue = rawValue
        self.label = label
        self.description = description
        self.rowHeight = rowHeight
        self.indentation = indentation
        self.iconSize = iconSize
    }
}

#endif
#endif
