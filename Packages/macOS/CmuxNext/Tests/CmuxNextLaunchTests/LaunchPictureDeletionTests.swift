import AppKit
import CmuxNextDesign
@testable import CmuxNextLaunch
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The saved launch pictures go with what they show (p08-startup-100): a test per path (Clear Browsing Data with and
/// without a range, a profile deleted, `launch.savedPicture` off, a tab closed, a window closed), the deletes never on
/// the main thread, and the quit's saves never undone by the closes that follow them.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LaunchPictureDeletionTests {
    static let work = BackgroundWork(label: "test.launch-picture-deletion")
    static let personal = UUID(), office = UUID()
    static let allowed = WindowPictureStore.Eligibility(incognito: false, onScreen: true, onActiveSpace: true, fullScreen: false,
                                                        hiddenFromCapture: false)

    /// The two stores' folders in a new temporary folder, and a deletion store over them.
    struct Saved {
        let root: URL
        let pages: BrowserLaunchPictures
        let windows: WindowPictureStore
        let store: LaunchPictureStore

        var pagesFolder: URL { root.appending(path: BrowserLaunchPictures.directoryName, directoryHint: .isDirectory) }
        var windowsFolder: URL { root.appending(path: WindowPictureStore.directoryName, directoryHint: .isDirectory) }

        /// Every saved file, relative to the root, sorted.
        var files: [String] {
            ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).filter { $0.contains(".") }.sorted()
        }

        func pageFile(_ key: String, profile: UUID) -> String { "\(BrowserLaunchPictures.directoryName)/\(profile.uuidString)/\(key).jpg" }
        func windowFile(_ window: String) -> String { "\(WindowPictureStore.directoryName)/default/\(window).heic" }
    }

    /// Saves pages `tab_a` (personal) and `tab_b` (work), and windows `w_a` (showing `tab_a`), `w_b` (showing `tab_b`),
    /// `w_top` (a top page such as History, drawn by AppKit: no pane) and `w_c` (a browser pane `tab_c` the quit took
    /// no page picture of: its tab strip still shows the page's title).
    static func saved(remove: (@Sendable (LaunchPictureStore.Deletion, LaunchPictureStore.Folders) -> Void)? = nil) async throws -> Saved {
        let root = FileManager.default.temporaryDirectory.appending(path: "launch-picture-deletion-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pages = BrowserLaunchPictures(state: root, work: work)
        let windows = WindowPictureStore(directory: root.appending(path: WindowPictureStore.directoryName, directoryHint: .isDirectory),
                                         work: work, encode: { _ in Data([1, 2, 3]) })
        let picture = BrowserLaunchPictures.Picture(image: try image(), paneSize: CGSize(width: 8, height: 6), pageFrame: CGRect(x: 0, y: 0, width: 8, height: 6))
        await pages.save([.init(key: "tab_a", profile: personal, picture: picture), .init(key: "tab_b", profile: office, picture: picture)])
        await windows.save([try shot("w_a", tab: "tab_a"), try shot("w_b", tab: "tab_b"), try shot("w_top", tab: nil),
                            try shot("w_c", tab: "tab_c")])
        let store = remove.map { LaunchPictureStore(pages: pages, windows: windows, work: work, remove: $0) }
            ?? LaunchPictureStore(pages: pages, windows: windows, work: work)
        return Saved(root: root, pages: pages, windows: windows, store: store)
    }

    static func image() throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return try #require(context.makeImage())
    }

    /// Window `window`'s picture showing tab `tab` in a pane (nil: no pane, a top page or the empty state).
    static func shot(_ window: String, tab: String?) throws -> WindowPictureStore.Shot {
        let meta = WindowPictureMeta(window: window, profile: "default", frame: CGRect(x: 0, y: 0, width: 8, height: 6), screen: "DISPLAY-1",
                                     scale: 1, appearance: NSAppearance.Name.darkAqua.rawValue, theme: "theme", sidebarWidth: 0,
                                     build: "1.0 (1)", layout: WindowPictureMeta.Layout(workspaces: ["ws_a"], shown: "ws_a", screens: []),
                                     regions: tab.map { [.init(kind: .pane, id: $0, frame: CGRect(x: 0, y: 0, width: 8, height: 6))] } ?? [])
        return WindowPictureStore.Shot(eligibility: allowed, base: try image(), size: CGSize(width: 8, height: 6), layers: [], fills: [],
                                       background: .init(red: 0, green: 0, blue: 0), meta: meta)
    }

    /// Clear Browsing Data over all time: the profile's page pictures and every window picture go, the ones with no
    /// page picture placed too (a top page, a browser pane with no page picture: AppKit drew their browsing data);
    /// the other profile's page pictures stay.
    @Test func clearingBrowsingDataDeletesTheProfilesPictures() async throws {
        let saved = try await Self.saved()
        defer { try? FileManager.default.removeItem(at: saved.root) }
        saved.store.delete(.browserProfile(Self.personal, since: nil))
        await saved.store.flush()
        #expect(!saved.files.contains(saved.pageFile("tab_a", profile: Self.personal)), "the cleared profile's page picture stayed")
        #expect(!saved.files.contains(saved.windowFile("w_a")), "a window picture showing the cleared profile stayed")
        #expect(!saved.files.contains(saved.windowFile("w_top")), "a window picture of a top page stayed")
        #expect(!saved.files.contains(saved.windowFile("w_c")), "a window picture of a browser pane with no page picture stayed")
        #expect(!saved.files.contains(saved.windowFile("w_b")), "a window picture stayed: its tab strip and sidebar may show the profile")
        #expect(saved.files.contains(saved.pageFile("tab_b", profile: Self.office)), "another profile's page picture went")
    }

    /// A clear marks its profile for the rest of the session: the quit's save leaves out the pictures of its open
    /// pages (they still show what they showed before it); another profile, a close and the setting off mark none.
    @Test func aClearWithholdsTheProfilesPicturesFromTheQuit() async throws {
        let store = LaunchPictureStore(pages: nil, windows: nil, work: Self.work)
        #expect(!store.withholdsPictures(ofProfile: Self.personal))
        store.delete(.browserProfile(Self.personal, since: Date(timeIntervalSinceNow: -3600)))
        await store.quitBegins()
        #expect(store.withholdsPictures(ofProfile: Self.personal), "the quit after a clear may picture the cleared profile's pages")
        #expect(!store.withholdsPictures(ofProfile: Self.office), "a clear withheld another profile's pictures")
        store.delete(.tab("tab_b"))
        store.delete(.all)
        #expect(!store.withholdsPictures(ofProfile: Self.office), "a close or the setting off marked a profile cleared")
    }

    /// Clear Browsing Data over a range: only pictures saved in it go.
    @Test func clearingARangeKeepsPicturesSavedBeforeIt() async throws {
        let saved = try await Self.saved()
        defer { try? FileManager.default.removeItem(at: saved.root) }
        let before = saved.files
        saved.store.delete(.browserProfile(Self.personal, since: Date(timeIntervalSinceNow: 3600)))
        await saved.store.flush()
        #expect(saved.files == before, "a picture saved before the range went")
        saved.store.delete(.browserProfile(Self.personal, since: Date(timeIntervalSinceNow: -3600)))
        await saved.store.flush()
        #expect(!saved.files.contains(saved.pageFile("tab_a", profile: Self.personal)), "a page picture saved in the range stayed")
        #expect(!saved.files.contains(saved.windowFile("w_a")) && !saved.files.contains(saved.windowFile("w_top")),
                "a window picture saved in the range stayed")
        #expect(saved.files.contains(saved.pageFile("tab_b", profile: Self.office)))
    }

    /// A profile deleted (the same deletion over all time): its pictures go on disk, and the launch read hands out no
    /// picture any more.
    @Test func deletingAProfileDeletesItsPicturesAndTheLaunchReadsOnes() async throws {
        let saved = try await Self.saved()
        defer { try? FileManager.default.removeItem(at: saved.root) }
        saved.pages.prefetch()
        await saved.pages.readFinished()
        saved.store.delete(.browserProfile(Self.office, since: nil))
        #expect(saved.pages.take("tab_a", profile: Self.personal) == nil, "the launch read handed out a picture after the delete")
        await saved.store.flush()
        #expect(!FileManager.default.fileExists(atPath: saved.pagesFolder.appending(path: Self.office.uuidString).path), "the profile's folder stayed")
        #expect(!saved.files.contains(saved.windowFile("w_b")))
        #expect(saved.files.contains(saved.pageFile("tab_a", profile: Self.personal)))
    }

    /// A closed tab: its page picture goes (the index no longer lists it) and so does every window picture showing it.
    @Test func closingATabDeletesItsPictures() async throws {
        let saved = try await Self.saved()
        defer { try? FileManager.default.removeItem(at: saved.root) }
        saved.store.delete(.tab("tab_a"))
        await saved.store.flush()
        #expect(!FileManager.default.fileExists(atPath: saved.pagesFolder.appending(path: Self.personal.uuidString).path),
                "the folder of a profile with no picture left stayed")
        #expect(!saved.files.contains(saved.windowFile("w_a")), "a window picture showing the closed tab stayed")
        #expect(saved.files.contains(saved.windowFile("w_b")) && saved.files.contains(saved.windowFile("w_c")), "another window's picture went")
        let read = BrowserLaunchPictures.readAll(in: saved.pagesFolder, LaunchFileReader())
        #expect(read.keys.map(\.key) == ["tab_b"], "the launch would still read the closed tab's picture, or lost another")
    }

    /// A tab closed among others in its profile: only its file goes and the index keeps the rest.
    @Test func closingATabKeepsItsProfilesOtherPictures() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "launch-picture-tab-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = BrowserLaunchPictures(state: root, work: Self.work)
        let picture = BrowserLaunchPictures.Picture(image: try Self.image(), paneSize: CGSize(width: 8, height: 6), pageFrame: CGRect(x: 0, y: 0, width: 8, height: 6))
        await pages.save([.init(key: "tab_a", profile: Self.personal, picture: picture), .init(key: "tab_b", profile: Self.personal, picture: picture)])
        let store = LaunchPictureStore(pages: pages, windows: nil, work: Self.work)
        store.delete(.tab("tab_a"))
        await store.flush()
        let folder = root.appending(path: "\(BrowserLaunchPictures.directoryName)/\(Self.personal.uuidString)", directoryHint: .isDirectory)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() == ["pictures.json", "tab_b.jpg"])
        let permissions = (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: "pictures.json").path))?[.posixPermissions] as? Int
        #expect(permissions == 0o600, "the rewritten index is not private")
    }

    /// A closed window: its picture goes, the others stay.
    @Test func closingAWindowDeletesItsPicture() async throws {
        let saved = try await Self.saved()
        defer { try? FileManager.default.removeItem(at: saved.root) }
        saved.store.delete(.window("w_b"))
        await saved.store.flush()
        #expect(!saved.files.contains(saved.windowFile("w_b")) && !saved.files.contains("\(WindowPictureStore.directoryName)/default/w_b.json"))
        #expect(saved.files.contains(saved.windowFile("w_a")) && saved.files.contains(saved.pageFile("tab_b", profile: Self.office)))
    }

    /// `launch.savedPicture` as the app reads it: nil until the settings load.
    @Observable @MainActor final class SavedPictureSetting {
        var value: Bool?
    }

    /// Runs the main run loop until `done` holds, for at most 5 s; returns `done()`.
    static func runMainLoop(until done: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return done()
    }

    /// Turning `launch.savedPicture` off deletes the window and page pictures at once, with no quit; while the settings
    /// have not loaded, and with it on, they stay.
    @Test func turningTheSettingOffDeletesEveryPictureWithNoQuit() async throws {
        let saved = try await Self.saved()
        defer { try? FileManager.default.removeItem(at: saved.root) }
        let setting = SavedPictureSetting()
        let follower = saved.store.followSavedPicture({ setting.value }, on: MainWorkScheduler.testing { _ in nil })
        defer { follower.cancel() }

        setting.value = true
        let flushed = Date(timeIntervalSinceNow: 0.2)
        _ = Self.runMainLoop { Date() >= flushed }  // the change's flush runs (RunLoop.run is unavailable in async code)
        await saved.store.flush()
        #expect(!saved.files.isEmpty, "the pictures went while the setting was not loaded or on")

        setting.value = false
        let gone = Self.runMainLoop {
            !FileManager.default.fileExists(atPath: saved.pagesFolder.path) && !FileManager.default.fileExists(atPath: saved.windowsFolder.path)
        }
        #expect(gone, "pictures stayed on disk with the setting off")
    }

    /// The acceptance: every deletion runs off the main thread, in the order asked.
    @Test func noDeleteRunsOnTheMainThread() async throws {
        let (runs, run) = AsyncStream.makeStream(of: (LaunchPictureStore.Deletion, Bool).self)
        let saved = try await Self.saved { deletion, _ in run.yield((deletion, Thread.isMainThread)) }
        defer { try? FileManager.default.removeItem(at: saved.root) }
        let asked: [LaunchPictureStore.Deletion] = [.browserProfile(Self.personal, since: nil), .tab("tab_a"), .window("w_a"), .all]
        for deletion in asked { saved.store.delete(deletion) }
        await saved.store.flush()
        run.finish()
        var seen: [(LaunchPictureStore.Deletion, Bool)] = []
        for await value in runs { seen.append(value) }
        #expect(seen.map { $0.0 } == asked, "a deletion did not run, or not in order")
        #expect(seen.allSatisfy { !$0.1 }, "a deletion ran on the main thread")
    }

    /// Once the quit's saves begin, a close deletes nothing (the quit ends sessions after saving their pictures); a
    /// clear still does.
    @Test func closesAfterTheQuitBeginsDeleteNothing() async throws {
        let saved = try await Self.saved()
        defer { try? FileManager.default.removeItem(at: saved.root) }
        await saved.store.quitBegins()
        saved.store.delete(.tab("tab_a"))
        saved.store.delete(.window("w_b"))
        await saved.store.flush()
        #expect(saved.files.contains(saved.pageFile("tab_a", profile: Self.personal)) && saved.files.contains(saved.windowFile("w_b")),
                "a close after the quit's saves began deleted a picture")
        saved.store.delete(.all)
        await saved.store.flush()
        #expect(saved.files.isEmpty, "the setting off during the quit kept pictures")
    }
}
