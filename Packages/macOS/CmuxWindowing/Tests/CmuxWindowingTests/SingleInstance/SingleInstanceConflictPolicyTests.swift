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
            SingleInstanceConflictPolicy.action(
                currentBundleURL: localRelease,
                existingBundleURL: stable,
                environment: [:]
            ) == .yieldToExisting
        )
    }

    @Test("an unknown running bundle path is never replaced")
    func unknownPathYields() {
        #expect(
            SingleInstanceConflictPolicy.action(currentBundleURL: stable, existingBundleURL: nil, environment: [:])
                == .yieldToExisting
        )
    }

    @Test("the same bundle relaunching itself replaces the older instance")
    func sameBundleReplaces() {
        let sameWithSlash = URL(fileURLWithPath: "/Applications/./cmux.app/", isDirectory: true)
        #expect(
            SingleInstanceConflictPolicy.action(currentBundleURL: stable, existingBundleURL: sameWithSlash, environment: [:])
                == .replaceExisting
        )
    }

    @Test("the explicit override restores replace-anything")
    func overrideReplaces() {
        #expect(
            SingleInstanceConflictPolicy.action(
                currentBundleURL: localRelease,
                existingBundleURL: stable,
                environment: [SingleInstanceConflictPolicy.allowReplacingEnvironmentKey: "1"]
            ) == .replaceExisting
        )
    }
}
