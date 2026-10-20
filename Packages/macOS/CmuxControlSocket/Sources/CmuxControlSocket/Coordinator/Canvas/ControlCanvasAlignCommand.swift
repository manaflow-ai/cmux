/// Wire names for `canvas.align` commands, validated at the coordinator so
/// unknown commands fail with `invalid_params` before crossing the seam. The
/// app maps each case onto the engine's `CanvasAlignmentCommand`.
public enum ControlCanvasAlignCommand: String, Sendable, CaseIterable {
    case tidy
    case alignLeft = "align-left"
    case alignRight = "align-right"
    case alignTop = "align-top"
    case alignBottom = "align-bottom"
    case equalizeWidths = "equalize-widths"
    case equalizeHeights = "equalize-heights"
    case distributeHorizontally = "distribute-horizontally"
    case distributeVertically = "distribute-vertically"
}
