import CmuxSimulator
import Foundation

struct SimulatorDeviceChromeProfile: Equatable, Sendable {
    typealias Insets = SimulatorDeviceChromeInsets
    typealias Button = SimulatorDeviceChromeButton

    let screenWidth: Double
    let screenHeight: Double
    let insets: Insets
    let devicePadding: Insets
    let cornerRadius: Double
    let screenCornerRadius: Double
    let assets: [String: URL]
    let compositeURL: URL?
    let buttons: [Button]

    var portraitWidth: Double { screenWidth + insets.leading + insets.trailing }
    var portraitHeight: Double { screenHeight + insets.top + insets.bottom }

    var bezelInsets: Insets {
        Insets(
            top: max(0, insets.top - devicePadding.top),
            leading: max(0, insets.leading - devicePadding.leading),
            bottom: max(0, insets.bottom - devicePadding.bottom),
            trailing: max(0, insets.trailing - devicePadding.trailing)
        )
    }

    var bodyRect: CGRect {
        CGRect(
            x: devicePadding.leading,
            y: devicePadding.bottom,
            width: portraitWidth - devicePadding.leading - devicePadding.trailing,
            height: portraitHeight - devicePadding.top - devicePadding.bottom
        )
    }

    func outerAspect(orientation: SimulatorOrientation) -> Double {
        switch orientation {
        case .portrait, .portraitUpsideDown:
            portraitWidth / portraitHeight
        case .landscapeLeft, .landscapeRight:
            portraitHeight / portraitWidth
        }
    }

    func screenRect(in bounds: CGRect, orientation: SimulatorOrientation) -> CGRect {
        let oriented = orientedGeometry(orientation)
        let outerAspect = oriented.width / oriented.height
        let boundsAspect = bounds.width / bounds.height
        let outerRect: CGRect
        if boundsAspect > outerAspect {
            let width = bounds.height * outerAspect
            outerRect = CGRect(x: bounds.midX - (width / 2), y: bounds.minY, width: width, height: bounds.height)
        } else {
            let height = bounds.width / outerAspect
            outerRect = CGRect(x: bounds.minX, y: bounds.midY - (height / 2), width: bounds.width, height: height)
        }
        let scale = outerRect.width / oriented.width
        return CGRect(
            x: outerRect.minX + (oriented.insets.leading * scale),
            y: outerRect.minY + (oriented.insets.bottom * scale),
            width: oriented.screenWidth * scale,
            height: oriented.screenHeight * scale
        )
    }

    func scaledScreenCornerRadius(
        in bounds: CGRect,
        orientation: SimulatorOrientation
    ) -> CGFloat {
        let oriented = orientedGeometry(orientation)
        guard oriented.screenWidth > 0 else { return 0 }
        return screenCornerRadius
            * screenRect(in: bounds, orientation: orientation).width
            / oriented.screenWidth
    }

    func button(at point: CGPoint, in bounds: CGRect, orientation: SimulatorOrientation) -> Button? {
        let oriented = orientedGeometry(orientation)
        let outerRect = outerRect(in: bounds, orientedWidth: oriented.width, orientedHeight: oriented.height)
        let normalized = CGPoint(
            x: (point.x - outerRect.minX) / outerRect.width * oriented.width,
            y: (point.y - outerRect.minY) / outerRect.height * oriented.height
        )
        return buttons.first { button in
            button.hidUsage != nil
                && orientedButtonRect(button.rect, orientation: orientation).contains(normalized)
        }
    }

    func contains(
        _ point: CGPoint,
        button: Button,
        in bounds: CGRect,
        orientation: SimulatorOrientation
    ) -> Bool {
        let oriented = orientedGeometry(orientation)
        let outerRect = outerRect(in: bounds, orientedWidth: oriented.width, orientedHeight: oriented.height)
        let normalized = CGPoint(
            x: (point.x - outerRect.minX) / outerRect.width * oriented.width,
            y: (point.y - outerRect.minY) / outerRect.height * oriented.height
        )
        return orientedButtonRect(button.rect, orientation: orientation).contains(normalized)
    }

    private func outerRect(
        in bounds: CGRect,
        orientedWidth: Double,
        orientedHeight: Double
    ) -> CGRect {
        let outerAspect = orientedWidth / orientedHeight
        let boundsAspect = bounds.width / bounds.height
        if boundsAspect > outerAspect {
            let width = bounds.height * outerAspect
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        }
        let height = bounds.width / outerAspect
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    private func orientedGeometry(_ orientation: SimulatorOrientation) -> (
        width: Double,
        height: Double,
        screenWidth: Double,
        screenHeight: Double,
        insets: Insets
    ) {
        switch orientation {
        case .portrait:
            (portraitWidth, portraitHeight, screenWidth, screenHeight, insets)
        case .portraitUpsideDown:
            (
                portraitWidth,
                portraitHeight,
                screenWidth,
                screenHeight,
                Insets(top: insets.bottom, leading: insets.trailing, bottom: insets.top, trailing: insets.leading)
            )
        case .landscapeLeft:
            (
                portraitHeight,
                portraitWidth,
                screenHeight,
                screenWidth,
                Insets(top: insets.trailing, leading: insets.top, bottom: insets.leading, trailing: insets.bottom)
            )
        case .landscapeRight:
            (
                portraitHeight,
                portraitWidth,
                screenHeight,
                screenWidth,
                Insets(top: insets.leading, leading: insets.bottom, bottom: insets.trailing, trailing: insets.top)
            )
        }
    }

    private func orientedButtonRect(_ rect: SimulatorRect, orientation: SimulatorOrientation) -> CGRect {
        switch orientation {
        case .portrait:
            CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        case .portraitUpsideDown:
            CGRect(
                x: portraitWidth - rect.x - rect.width,
                y: portraitHeight - rect.y - rect.height,
                width: rect.width,
                height: rect.height
            )
        case .landscapeLeft:
            CGRect(
                x: rect.y,
                y: portraitWidth - rect.x - rect.width,
                width: rect.height,
                height: rect.width
            )
        case .landscapeRight:
            CGRect(
                x: portraitHeight - rect.y - rect.height,
                y: rect.x,
                width: rect.height,
                height: rect.width
            )
        }
    }
}
