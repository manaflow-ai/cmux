public import Foundation

/// The canvas-domain slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella).
///
/// The app conformer resolves routing to a workspace and drives the
/// workspace's canvas model and viewport. No app types cross the seam:
/// reads return `ControlCanvas*` snapshots, mutations take pre-parsed
/// selectors and return ``ControlCanvasActionResolution``.
@MainActor
public protocol ControlCanvasContext: AnyObject {
    /// Snapshots the resolved workspace's canvas state for `canvas.info`.
    /// Returns `nil` when no workspace resolves.
    func controlCanvasInfo(routing: ControlRoutingSelectors) -> ControlCanvasInfoSnapshot?

    /// Sets the layout mode for `canvas.set_mode`. `mode` is `"canvas"`,
    /// `"splits"`, or `"toggle"` (validated by the coordinator).
    func controlCanvasSetMode(
        routing: ControlRoutingSelectors,
        mode: String
    ) -> ControlCanvasActionResolution

    /// Moves/resizes one canvas pane for `canvas.set_frame`.
    func controlCanvasSetFrame(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        frame: ControlCanvasFrame
    ) -> ControlCanvasActionResolution

    /// Applies an alignment command to all canvas panes for `canvas.align`.
    func controlCanvasAlign(
        routing: ControlRoutingSelectors,
        command: ControlCanvasAlignCommand
    ) -> ControlCanvasActionResolution

    /// Scrolls a pane into view for `canvas.reveal` (`nil` = focused pane).
    func controlCanvasReveal(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlCanvasActionResolution

    /// Toggles the fit-all overview zoom for `canvas.overview`.
    func controlCanvasToggleOverview(
        routing: ControlRoutingSelectors
    ) -> ControlCanvasActionResolution

    /// Zooms the canvas viewport for `canvas.zoom`.
    func controlCanvasZoom(
        routing: ControlRoutingSelectors,
        direction: ControlCanvasZoomDirection
    ) -> ControlCanvasActionResolution

    /// Moves a surface into the pane hosting `targetSurfaceID` for
    /// `canvas.join`.
    func controlCanvasJoin(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        targetSurfaceID: UUID
    ) -> ControlCanvasActionResolution

    /// Tears a surface out of its multi-tab pane for `canvas.break`.
    func controlCanvasBreak(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlCanvasActionResolution

    /// Selects a surface as its pane's visible tab for `canvas.select_tab`.
    func controlCanvasSelectTab(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlCanvasActionResolution

    /// Centers and zooms the viewport for `canvas.set_viewport`. `center` is
    /// in canvas coordinates; `magnification` nil keeps the current zoom.
    func controlCanvasSetViewport(
        routing: ControlRoutingSelectors,
        centerX: Double,
        centerY: Double,
        magnification: Double?
    ) -> ControlCanvasActionResolution

    /// Creates a new free-floating canvas pane for `canvas.new_pane`. `type`
    /// is `"terminal"` or `"browser"`. Returns `.created` carrying the new
    /// surface id.
    func controlCanvasNewPane(
        routing: ControlRoutingSelectors,
        type: String
    ) -> ControlCanvasActionResolution
}
