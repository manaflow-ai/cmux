@testable import CmuxAndroidEmulator
import Foundation
import Testing

@Suite
struct AndroidEmulatorProcessIdentityTests {
    @Test
    func matchesExactAVDArgumentForms() {
        let argumentsByProcessIdentifier: [Int32: [String]] = [
            101: ["qemu-system-aarch64", "-avd", "Pixel_9", "-port", "5556"],
            102: ["emulator", "@Pixel_9"],
            103: ["qemu-system-aarch64", "-avd", "Pixel_9_Pro"],
            104: ["qemu-system-aarch64", "-avd", "Pixel_9", "-ports", "5558,5559"],
        ]
        let identity = AndroidEmulatorProcessIdentity { processIdentifier in
            argumentsByProcessIdentifier[processIdentifier]
        }

        #expect(identity.matches(processIdentifier: 101, avdName: "Pixel_9", serial: "emulator-5556"))
        #expect(!identity.matches(processIdentifier: 101, avdName: "Pixel_9", serial: "emulator-5554"))
        #expect(identity.matches(processIdentifier: 102, avdName: "Pixel_9", serial: "emulator-5554"))
        #expect(!identity.matches(processIdentifier: 102, avdName: "Pixel_9", serial: "emulator-5556"))
        #expect(!identity.matches(processIdentifier: 103, avdName: "Pixel_9", serial: "emulator-5554"))
        #expect(identity.matches(processIdentifier: 104, avdName: "Pixel_9", serial: "emulator-5558"))
        #expect(!identity.matches(processIdentifier: 105, avdName: "Pixel_9", serial: "emulator-5554"))
        #expect(!identity.matches(processIdentifier: 0, avdName: "Pixel_9", serial: "emulator-5554"))
        #expect(!identity.matches(processIdentifier: 101, avdName: "Pixel_9", serial: "device-5556"))
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
