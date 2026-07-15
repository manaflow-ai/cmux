import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserChromiumProfileDirectoryTests {
    @Test func sameProfileUsesOnePersistentDirectory() {
        let builder = BrowserChromiumProfileDirectory(
            applicationSupportDirectory: URL(fileURLWithPath: "/application-support"),
            bundleIdentifier: "com.cmuxterm.app"
        )
        let profileID = UUID()

        let firstSession = builder.url(profileID: profileID)
        let secondSession = builder.url(profileID: profileID)

        #expect(firstSession == secondSession)
    }

    @Test func separatesProfileDirectories() {
        let builder = BrowserChromiumProfileDirectory(
            applicationSupportDirectory: URL(fileURLWithPath: "/application-support"),
            bundleIdentifier: "com.cmuxterm.app"
        )
        let firstProfileID = UUID(uuidString: "7F71E21E-4F75-4FD7-B7F0-2DD8566A50CD")!
        let secondProfileID = UUID(uuidString: "09BDB8FD-9B35-40F8-82C1-07D6FA4A5905")!

        #expect(builder.url(profileID: firstProfileID) != builder.url(profileID: secondProfileID))
    }

    @Test func normalizesTaggedDebugStorage() {
        let profileID = UUID()
        let applicationSupport = URL(fileURLWithPath: "/application-support")
        let first = BrowserChromiumProfileDirectory(
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.debug.first"
        )
        let second = BrowserChromiumProfileDirectory(
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.debug.second"
        )

        #expect(first.url(profileID: profileID) == second.url(profileID: profileID))
    }
}
