import Foundation

/// Settings under the dotted-id prefix `canvas.*`.
///
/// Controls canvas-family workspace layouts. ``paneGap`` is the one
/// canonical spacing every canvas operation respects (snapping targets,
/// tidy/distribute commands, new-pane placement); ``snappingEnabled``
/// turns edge/gap snapping during drags and resizes on or off (Command
/// always suspends snapping for one gesture either way). ``splitDividerThickness``
/// controls packed Bonsplit dividers in split and zoomable split layouts.
public struct CanvasCatalogSection: SettingCatalogSection {
    /// Gap between panes, in canvas points, used by snapping and every
    /// alignment/placement command.
    public let paneGap = DefaultsKey<Int>(
        id: "canvas.paneGap",
        defaultValue: 16,
        userDefaultsKey: "canvasPaneGap"
    )

    /// Whether drags and resizes snap to neighbor edges and the canonical
    /// gap. Holding Command suspends snapping per-gesture regardless.
    public let snappingEnabled = DefaultsKey<Bool>(
        id: "canvas.snappingEnabled",
        defaultValue: true,
        userDefaultsKey: "canvasSnappingEnabled"
    )

    /// Thickness of packed split-tree dividers, in points.
    public let splitDividerThickness = DefaultsKey<Int>(
        id: "canvas.splitDividerThickness",
        defaultValue: 1,
        userDefaultsKey: "canvasSplitDividerThickness"
    )

    /// Creates the canvas settings section with its default keys.
    public init() {}
}
