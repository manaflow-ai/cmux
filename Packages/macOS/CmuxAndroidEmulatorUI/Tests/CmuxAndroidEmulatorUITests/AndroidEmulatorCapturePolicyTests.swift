@testable import CmuxAndroidEmulatorUI
import CmuxAndroidEmulator
import CoreGraphics
import Foundation
import Testing

@Suite
struct AndroidEmulatorCapturePolicyTests {
    @Test
    func acceptsOnlyExecutablesInsideSelectedSDKEmulatorDirectory() {
        let sdkRoot = URL(fileURLWithPath: "/Users/test/Library/Android/sdk")

        #expect(AndroidEmulatorCapturePolicy.isExpectedEmulatorExecutable(
            sdkRoot.appendingPathComponent("emulator/qemu/darwin-aarch64/qemu-system-aarch64"),
            sdkRootURL: sdkRoot
        ))
        #expect(!AndroidEmulatorCapturePolicy.isExpectedEmulatorExecutable(
            URL(fileURLWithPath: "/Applications/Fake Emulator.app/Contents/MacOS/qemu-system-aarch64"),
            sdkRootURL: sdkRoot
        ))
        #expect(!AndroidEmulatorCapturePolicy.isExpectedEmulatorExecutable(
            URL(fileURLWithPath: "/Users/test/Library/Android/sdk-evil/emulator/qemu-system-aarch64"),
            sdkRootURL: sdkRoot
        ))
    }

    @Test
    func derivesViewportFromWindowAndDeviceAspectRatio() {
        let rect = AndroidEmulatorCapturePolicy.sourceRect(
            windowSize: CGSize(width: 411, height: 951),
            displaySize: AndroidEmulatorDisplaySize(width: 1080, height: 2424)
        )

        #expect(rect.origin.x == 0)
        #expect(abs(rect.origin.y - 28.6) < 0.1)
        #expect(rect.width == 411)
        #expect(abs(rect.height - 922.4) < 0.1)
    }

    @Test
    func ranksTheDeviceWindowAheadOfVendorAuxiliaryWindows() {
        let aspect = CGFloat(1080) / CGFloat(2424)

        #expect(
            AndroidEmulatorCapturePolicy.aspectError(
                CGSize(width: 411, height: 951),
                deviceAspect: aspect
            ) < AndroidEmulatorCapturePolicy.aspectError(
                CGSize(width: 54, height: 506),
                deviceAspect: aspect
            )
        )
    }
}
