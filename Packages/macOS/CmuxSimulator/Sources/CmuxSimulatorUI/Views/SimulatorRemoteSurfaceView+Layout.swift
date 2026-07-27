import AppKit
import CmuxSimulator
import QuartzCore

extension SimulatorRemoteSurfaceView {
    var displayRect: CGRect {
        guard let display else { return bounds }
        if let chrome {
            return chrome.screenRect(in: bounds, orientation: display.orientation)
        }
        let layout = SimulatorDisplayLayout(
            surface: SimulatorSurfaceGeometry(
                width: bounds.width,
                height: bounds.height,
                scale: Double(window?.backingScaleFactor ?? 2)
            ),
            display: display
        )
        let rect = layout.contentRect
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    var orientationGeometry: SimulatorOrientationGeometry? {
        display.map(SimulatorOrientationGeometry.init(display:))
    }

    func updateChromeLayerBackground() {
        layer?.backgroundColor = chrome == nil ? NSColor.black.cgColor : NSColor.clear.cgColor
    }

    func layoutFrameLayer() {
        guard let frameLayer else { return }
        let rect = displayRect
        let geometry = orientationGeometry
        let swapsAxes = geometry?.swapsAxes == true
        let rawSize = CGSize(
            width: swapsAxes ? rect.height : rect.width,
            height: swapsAxes ? rect.width : rect.height
        )
        let radians = CGFloat(geometry?.presentationRotationDegrees ?? 0) * .pi / 180
        let radius =
            if let chrome, let display {
                chrome.scaledScreenCornerRadius(in: bounds, orientation: display.orientation)
            } else {
                CGFloat.zero
            }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.bounds = CGRect(origin: .zero, size: rawSize)
        frameLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        frameLayer.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
        frameLayer.cornerRadius = radius
        frameLayer.cornerCurve = .continuous
        frameLayer.masksToBounds = true
        CATransaction.commit()
    }
}
