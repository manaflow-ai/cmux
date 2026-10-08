import CmuxWindowing
import Foundation
import Testing

@Suite("Single-instance conflict policy")
struct SingleInstanceConflictPolicyTests {
    private let stable = URL(fileURLWithPath: "/Applications/cmux.app", isDirectory: true)
    private let localRelease = URL(
        fileURLWithPath: "/Users/dev/Library/Developer/Xcode/DerivedData/cmux-abc/Build/Products/Release/cmux.app",
        isDirectory: true
    )

    @Test("a different bundle with the stable id leaves the running app alone")
    func otherBundleYields() {
        #expect(
            SingleInstanceConflictPolicy(environment: [:]).action(currentBundleURL: localRelease, existingBundleURL: stable) == .yieldToExisting
        )
    }

    @Test("an unknown running bundle path is never replaced")
    func unknownPathYields() {
        #expect(
            SingleInstanceConflictPolicy(environment: [:]).action(currentBundleURL: stable, existingBundleURL: nil)
                == .yieldToExisting
        )
    }

    @Test("a same-bundle relaunch leaves the existing instance alone")
    func sameBundleYields() {
        let sameWithSlash = URL(fileURLWithPath: "/Applications/./cmux.app/", isDirectory: true)
        #expect(
            SingleInstanceConflictPolicy(environment: [:]).action(currentBundleURL: stable, existingBundleURL: sameWithSlash)
                == .yieldToExisting
        )
        #expect(SingleInstanceConflictPolicy.isSameBundle(stable, sameWithSlash))
    }

    @Test("an authorized relaunch can replace the existing instance")
    func authorizedRelaunchReplaces() {
        #expect(
            SingleInstanceConflictPolicy(environment: [:]).action(
                currentBundleURL: stable,
                existingBundleURL: stable,
                replacementAuthorized: true
            ) == .replaceExisting
        )
    }

    @Test("the explicit override restores replace-anything")
    func overrideReplaces() {
        #expect(
            SingleInstanceConflictPolicy(environment: [SingleInstanceConflictPolicy.allowReplacingEnvironmentKey: "1"]).action(currentBundleURL: localRelease, existingBundleURL: stable) == .replaceExisting
        )
    }
}
