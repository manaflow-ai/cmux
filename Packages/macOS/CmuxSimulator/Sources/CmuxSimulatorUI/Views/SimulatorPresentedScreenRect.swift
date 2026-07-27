import CmuxSimulator
import Foundation

func simulatorPresentedScreenRect(
    in bounds: CGRect,
    chrome: SimulatorDeviceChromeProfile?,
    orientation: SimulatorOrientation
) -> CGRect {
    let appKitScreen = chrome?.screenRect(
        in: bounds,
        orientation: orientation
    ) ?? bounds
    return CGRect(
        x: appKitScreen.minX,
        y: bounds.height - appKitScreen.maxY,
        width: appKitScreen.width,
        height: appKitScreen.height
    )
}
