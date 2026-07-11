@testable import CmuxAndroidEmulator
import Foundation
import Testing

@Suite
struct AndroidEmulatorProcessIdentityTests {
    @Test
    func matchesExactAVDArgumentForms() {
        #expect(AndroidEmulatorProcessIdentity.argumentsMatchAVD(
            ["qemu-system-aarch64", "-avd", "Pixel_9"],
            avdName: "Pixel_9"
        ))
        #expect(AndroidEmulatorProcessIdentity.argumentsMatchAVD(
            ["emulator", "@Pixel_9"],
            avdName: "Pixel_9"
        ))
        #expect(!AndroidEmulatorProcessIdentity.argumentsMatchAVD(
            ["qemu-system-aarch64", "-avd", "Pixel_9_Pro"],
            avdName: "Pixel_9"
        ))
    }

    @Test
    func parsesKernelProcessArguments() {
        let arguments = ["qemu-system-aarch64", "-avd", "Pixel_9"]
        var argc = Int32(arguments.count).littleEndian
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/sdk/emulator/qemu\0\0".utf8)
        for argument in arguments {
            bytes += Array(argument.utf8) + [0]
        }

        #expect(AndroidEmulatorProcessIdentity.parseKernProcArguments(bytes) == arguments)
    }
}
