import CoreGraphics

/// Decides which wheel events should be handed to the native Pages strip.
struct CanvasPagesScrollRouting: Equatable {
    func shouldRouteToNativePages(
        deltaX: CGFloat,
        deltaY: CGFloat,
        isShiftPressed: Bool
    ) -> Bool {
        if isShiftPressed {
            return deltaX != 0 || deltaY != 0
        }

        return abs(deltaX) > abs(deltaY) && deltaX != 0
    }
}
