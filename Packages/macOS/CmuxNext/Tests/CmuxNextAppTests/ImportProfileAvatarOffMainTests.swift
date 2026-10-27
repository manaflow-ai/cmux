import AppKit
import CmuxNextBrowserImport
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// A profile row's picture is read and decoded off the main thread (p03-rendering-121): before, each row read the
/// file and decoded it in its configure, on the main thread, as the import step rendered. Now the step asks the
/// services for every profile's picture once, after detection, and the rows show what came back.
@MainActor @Suite(.serialized) struct ImportProfileAvatarOffMainTests {
    /// Main-actor turns until `condition`: the mock answers at once, so the step's detection task needs only turns.
    private static func until(_ condition: () -> Bool) async {
        var turns = 0
        while !condition(), turns < 10_000 {
            turns += 1
            await Task.yield()
        }
    }

    @Test func theStepAsksForEveryPictureOnceAtTheRowSize() async {
        let picture = URL(fileURLWithPath: "/tmp/chrome/Profile 1/Google Profile Picture.png")
        let work = BrowserSourceProfile(browser: .chrome, directoryName: "Profile 1", displayName: "Work",
                                        path: URL(fileURLWithPath: "/tmp/chrome/Profile 1"),
                                        availability: [.bookmarks: .available], avatar: picture)
        let personal = BrowserSourceProfile(browser: .chrome, directoryName: "Default", displayName: "Personal",
                                            path: URL(fileURLWithPath: "/tmp/chrome/Default"), availability: [.bookmarks: .available])
        let services = MockOnboardingServices()
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [personal, work])]
        let image = NSImage(size: NSSize(width: 16, height: 16))
        services.avatars = [picture: image]
        let step = OnboardingModel(services: services, step: .importData).importer

        step.detect()
        await Self.until { !step.profileAvatars.isEmpty }

        #expect(services.avatarRequests.count == 1)
        #expect(services.avatarRequests.first?.files == [picture], "only profiles with a picture are read")
        #expect(services.avatarRequests.first?.points == ImportProfileRow.avatarSide)
        #expect(step.profileAvatars[picture] === image)
    }
}
