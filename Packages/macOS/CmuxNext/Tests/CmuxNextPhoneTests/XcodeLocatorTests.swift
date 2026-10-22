import Foundation
import Testing
@testable import CmuxNextPhone

/// Finding Xcode on disk, never through xcrun (u9770: onboarding for people without Xcode).
@Suite struct XcodeLocatorTests {
    static let xcode = "/Applications/Xcode.app/Contents/Developer"
    static let beta = "/Applications/Xcode-beta.app/Contents/Developer"
    static let tools = "/Library/Developer/CommandLineTools"

    func locator(link: String? = nil, apps: [String] = [], files: Set<String> = [], environment: [String: String] = [:]) -> XcodeLocator {
        XcodeLocator(environment: environment, selectedLink: { link }, fileExists: { files.contains($0) }, applications: { apps })
    }

    @Test func aNewMacHasNoXcode() {
        let found = locator()
        #expect(found.developerDirectory() == nil)
        #expect(!found.hasOnlyCommandLineTools)
    }

    @Test func commandLineToolsAloneAreNotEnoughAndAreNamed() {
        let found = locator(link: Self.tools, files: [Self.tools + "/usr/bin/clang"])
        #expect(found.developerDirectory() == nil)
        #expect(found.hasOnlyCommandLineTools)
    }

    @Test func xcodeInstalledAfterTheCommandLineToolsIsUsedWithoutXcodeSelect() {
        let found = locator(link: Self.tools, apps: ["/Applications/Xcode.app"],
                            files: [Self.tools + "/usr/bin/clang", Self.xcode + "/usr/bin/simctl"])
        #expect(found.developerDirectory() == Self.xcode)
        #expect(found.xcodeApp() == "/Applications/Xcode.app")
    }

    @Test func theSelectedXcodeWinsThenXcodeAppThenABeta() {
        let files: Set<String> = [Self.xcode + "/usr/bin/simctl", Self.beta + "/usr/bin/simctl"]
        let apps = ["/Applications/Xcode-beta.app", "/Applications/Xcode.app"]
        #expect(locator(link: Self.beta, apps: apps, files: files).developerDirectory() == Self.beta)
        #expect(locator(apps: apps, files: files).developerDirectory() == Self.xcode)
        #expect(locator(apps: ["/Applications/Xcode-beta.app"], files: files).developerDirectory() == Self.beta)
        #expect(locator(environment: ["DEVELOPER_DIR": Self.beta], apps: apps, files: files).developerDirectory() == Self.beta)
    }

    @Test func anXcodeBundleWithoutSimctlIsNotUsed() {
        #expect(locator(apps: ["/Applications/Xcode.app"]).developerDirectory() == nil)
    }
}
