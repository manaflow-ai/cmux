@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextSettings
import Foundation
import Testing

/// The browser preferences follow cmux.json through scheduled observations
/// (`ServiceObservation`), not main-inherited `ObservationStream` loops. The current value applies in
/// the follow's own turn, before any page reads it; a later change of the file reaches the engines
/// as a task on the app's scheduler, and only while the owner keeps the returned followers.
@MainActor @Suite(.serialized) struct BrowserPreferenceFollowTests {
    final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "cnc-browser-follow-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var file: URL { url.appending(path: "cmux-next.json") }
        func write(_ json: String) throws { try Data(json.utf8).write(to: file) }
    }

    static func settings(_ folder: Folder) async -> SettingsController {
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: folder.file,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return settings
    }

    @Test func theDefaultEngineAppliesInTheFollowsTurnAndAFileChangeAfter() async throws {
        let folder = try Folder()
        try folder.write(#"{"browser":{"defaultEngine":"webkit"}}"#)
        let settings = await Self.settings(folder)
        let preference = BrowserEnginePreference()
        preference.follow(settings, on: linklessMainWork())
        #expect(preference.defaultEngine == .webkit, "the current value applies before follow returns")

        try folder.write(#"{"browser":{"defaultEngine":"chromium"}}"#)
        await settings.reload()
        #expect(runMainLoop { preference.defaultEngine == .chromium }, "the file's change reaches the preference")
    }

    @Test func linkClicksFollowOnlyWhileTheOwnerKeepsTheFollowers() async throws {
        let folder = try Folder()
        try folder.write(#"{"browser":{"links":{"cmdClick":"currentTab"}}}"#)
        let settings = await Self.settings(folder)
        let webKit = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let chromium = ChromiumEngineSlot(CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap()))
        var followers: [AnyObject]? = BrowserLinkClickPreference.follow(settings, webKit: webKit, chromium: chromium, on: linklessMainWork())
        let current = BrowserLinkClickMapping(settings.snapshot.browserLinkClicks)
        #expect(webKit.linkClicks == current, "the current mapping applies before follow returns")

        try folder.write(#"{"browser":{"links":{"cmdClick":"foregroundTab"}}}"#)
        await settings.reload()
        let changed = BrowserLinkClickMapping(settings.snapshot.browserLinkClicks)
        #expect(changed != current)
        #expect(runMainLoop { webKit.linkClicks == changed }, "the file's change reaches WebKit as a posted task")
        #expect(followers?.count == 2, "the link clicks and the managed policy")

        followers = nil
        try folder.write(#"{"browser":{"links":{"cmdClick":"backgroundTab"}}}"#)
        await settings.reload()
        runMainLoopPass(for: 0.2)
        #expect(webKit.linkClicks == changed, "released followers apply nothing")
    }
}
