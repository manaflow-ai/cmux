import CmuxControlSocket

extension ControlCanvasContext {
    func controlCanvasStrings() -> ControlCanvasStrings {
        ControlCanvasStrings(
            invalidMode: "mode must be canvas, zoomableSplits, splits, or toggle",
            notCanvasOrZoomable: "Workspace is not in canvas or zoomable split layout (run canvas.set_mode first)",
            requiresFreeformCanvas: "Command requires freeform canvas layout (run canvas.set_mode with mode=canvas first)"
        )
    }
}
