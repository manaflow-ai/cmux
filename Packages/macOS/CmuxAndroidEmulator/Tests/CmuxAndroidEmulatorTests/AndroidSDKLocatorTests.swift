@testable import CmuxAndroidEmulator
import Foundation
import Testing

@Suite struct AndroidSDKLocatorTests {
    @Test func configuredSDKPrecedesConventionalLocation() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let files = StubAndroidSDKFileChecker(
            directories: ["/custom/sdk", "/Users/test/Library/Android/sdk"],
            executables: [
                "/custom/sdk/emulator/emulator",
                "/custom/sdk/platform-tools/adb",
                "/Users/test/Library/Android/sdk/emulator/emulator",
            ]
        )
        let locator = AndroidSDKLocator(
            environment: [
                "ANDROID_HOME": "/custom/sdk",
                "ANDROID_SDK_ROOT": "/ignored/sdk",
            ],
            homeDirectoryURL: home,
            files: files
        )

        #expect(locator.locate() == .available(AndroidSDKInstallation(
            rootURL: URL(fileURLWithPath: "/custom/sdk", isDirectory: true),
            emulatorURL: URL(fileURLWithPath: "/custom/sdk/emulator/emulator"),
            adbURL: URL(fileURLWithPath: "/custom/sdk/platform-tools/adb")
        )))
    }

    @Test func existingSDKWithoutEmulatorReportsSelectedRoot() {
        let locator = AndroidSDKLocator(
            environment: ["ANDROID_SDK_ROOT": "/partial/sdk"],
            homeDirectoryURL: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            files: StubAndroidSDKFileChecker(
                directories: ["/partial/sdk"],
                executables: []
            )
        )

        #expect(locator.locate() == .emulatorMissing(
            rootURL: URL(fileURLWithPath: "/partial/sdk", isDirectory: true)
        ))
    }
}

private struct StubAndroidSDKFileChecker: AndroidSDKFileChecking {
    let directories: Set<String>
    let executables: Set<String>

    func directoryExists(atPath path: String) -> Bool {
        directories.contains(path)
    }

    func executableExists(atPath path: String) -> Bool {
        executables.contains(path)
    }
}
