import CoreGraphics

/// Encapsulates Figma-style Space+drag pan decisions and drag math.
struct CanvasSpacePanBehavior {
    func clipOrigin(
        startClipOrigin: CGPoint,
        startWindowPoint: CGPoint,
        currentWindowPoint: CGPoint,
        magnification: CGFloat
    ) -> CGPoint {
        let scale = max(magnification, 0.0001)
        let dx = (currentWindowPoint.x - startWindowPoint.x) / scale
        let dy = (currentWindowPoint.y - startWindowPoint.y) / scale
        return CGPoint(
            x: startClipOrigin.x - dx,
            y: startClipOrigin.y + dy
        )
    }

    func shouldConsumeSpaceKey(
        isPointerInsideCanvas: Bool,
        canInterceptKeyboardTarget: Bool,
        isPanning: Bool
    ) -> Bool {
        isPanning || (isPointerInsideCanvas && canInterceptKeyboardTarget)
    }

    func shouldConsumeSpaceKeyRepeat(
        didConsumeSpaceKey: Bool,
        isPanning: Bool
    ) -> Bool {
        didConsumeSpaceKey || isPanning
    }

    func canBeginPan(
        didConsumeSpaceKey: Bool,
        isPhysicalSpaceKeyPressed: Bool,
        isPointerInsideCanvas: Bool
    ) -> Bool {
        didConsumeSpaceKey && isPhysicalSpaceKeyPressed && isPointerInsideCanvas
    }

    func shouldHandleEvents(isWorkspaceVisible: Bool) -> Bool {
        isWorkspaceVisible
    }
}
