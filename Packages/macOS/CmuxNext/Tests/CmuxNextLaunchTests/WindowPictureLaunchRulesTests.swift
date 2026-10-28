import AppKit
import CmuxNextCompat
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CoreGraphics
import Foundation
import Observation
import Testing
import UniformTypeIdentifiers

/// When a launch may show the front window's saved picture, and what the picture may show: a test
/// per invalidation rule (the setting off, crash recovery, incognito leftovers, each whole-picture meta field, each
/// layout region) and per privacy fill (Secure Input, a withheld page, a page with no picture), plus the store
/// handing out only an allowed picture and recording why it refused one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WindowPictureLaunchRulesTests {
    static let work = BackgroundWork(label: "test.window-picture-rules")
    static let allowedLaunch = WindowPictureStore.LaunchFacts(savedPicture: true, recovered: false, incognitoLeftovers: false)
    nonisolated static let window = "0b5c7d3e-6f1a-4b2c-9d8e-1f2a3b4c5d6e"
    static let png: @Sendable (CGImage) -> Data? = { blockingImageEncode($0, type: UTType.png.identifier as CFString) }

    static func meta(workspaces: [String] = ["ws_a", "ws_b"], tree: WindowPictureMeta.PaneTree = .leaf("1")) -> WindowPictureMeta {
        WindowPictureMeta(window: window, profile: "default", frame: CGRect(x: 100, y: 200, width: 8, height: 6), screen: "DISPLAY-1",
                          scale: 2, appearance: NSAppearance.Name.darkAqua.rawValue, theme: WindowPictureMeta.fingerprint(["theme"]),
                          sidebarWidth: 240, build: "1.0 (1)",
                          layout: WindowPictureMeta.Layout(workspaces: workspaces, shown: "ws_a", screens: [.init(id: "scr_1", tree: tree, zoomed: nil)]),
                          regions: [.init(kind: .sidebar, id: "sidebar", frame: CGRect(x: 0, y: 0, width: 2, height: 6)),
                                    .init(kind: .pane, id: "tab_a", frame: CGRect(x: 2, y: 0, width: 6, height: 6))])
    }

    static func facts(_ change: (inout WindowPictureStore.LaunchFacts) -> Void) -> WindowPictureStore.LaunchFacts {
        var facts = allowedLaunch
        change(&facts)
        return facts
    }

    static func opening(_ change: (inout WindowPictureMeta) -> Void) -> WindowPictureMeta {
        var meta = meta()
        change(&meta)
        return meta
    }

    static func image(color: CGColor?) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if let color {
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        return try #require(context.makeImage())
    }

    // MARK: Invalidation

    @Test func aMatchingWindowShowsThePictureWhole() {
        #expect(WindowPictureStore.use(Self.meta(), for: Self.meta(), launch: Self.allowedLaunch) == .show(stale: []))
    }

    @Test func theSettingOffShowsNone() {
        #expect(WindowPictureStore.use(Self.meta(), for: Self.meta(), launch: Self.facts { $0.savedPicture = false }) == .refuse(.settingOff))
    }

    /// The pictures on disk are from the quit before the run that crashed: never shown after it.
    @Test func crashRecoveryShowsNone() {
        #expect(WindowPictureStore.use(Self.meta(), for: Self.meta(), launch: Self.facts { $0.recovered = true }) == .refuse(.crashRecovery))
    }

    /// After `kill -9` the launch is not a crash recovery, but the picture is still the quit's before
    /// the killed run, terminal regions included, while the daemon's newer screens come live: never shown under
    /// `relaunchReattach`, which says so through the same value as the terminal frames' discard.
    @Test func aKillNineLaunchThatReattachesShowsNone() {
        let killed = RelaunchReattach(previousEnd: .killed, enabled: true)
        #expect(WindowPictureStore.use(Self.meta(), for: Self.meta(), launch: Self.facts { $0.savedScreensStale = !killed.keepsSavedScreens })
            == .refuse(.reattach))
        let off = RelaunchReattach(previousEnd: .killed, enabled: false)
        #expect(WindowPictureStore.use(Self.meta(), for: Self.meta(), launch: Self.facts { $0.savedScreensStale = !off.keepsSavedScreens })
            == .show(stale: []), "the feature off keeps today's launch")
        let shutdown = RelaunchReattach(previousEnd: .systemShutdown, enabled: true)
        #expect(WindowPictureStore.use(Self.meta(), for: Self.meta(), launch: Self.facts { $0.savedScreensStale = !shutdown.keepsSavedScreens })
            == .show(stale: []), "no daemon survived a reboot: the picture is the best first frame")
    }

    @Test func incognitoLeftoversShowNone() {
        #expect(WindowPictureStore.use(Self.meta(), for: Self.meta(), launch: Self.facts { $0.incognitoLeftovers = true })
            == .refuse(.incognitoLeftovers))
    }

    /// Each whole-picture field that changed refuses the picture with its own reason.
    @Test func aChangedScreenScaleAppearanceThemeOrBuildShowsNone() {
        let cases: [(WindowPictureStore.Refusal, WindowPictureMeta)] = [
            (.screen, Self.opening { $0.screen = "DISPLAY-2" }),
            (.scale, Self.opening { $0.scale = 1 }),
            (.appearance, Self.opening { $0.appearance = NSAppearance.Name.aqua.rawValue }),
            (.theme, Self.opening { $0.theme = WindowPictureMeta.fingerprint(["another theme"]) }),
            (.build, Self.opening { $0.build = "1.0 (2)" }),
            (.frame, Self.opening { $0.frame.size.width += 40 }),
            (.sidebarWidth, Self.opening { $0.sidebarWidth = 300 }),
            (.format, Self.opening { $0.format += 1 }),
        ]
        for (refusal, opening) in cases {
            #expect(WindowPictureStore.use(Self.meta(), for: opening, launch: Self.allowedLaunch) == .refuse(refusal), "\(refusal)")
        }
    }

    /// The launch's own facts come first, then the fields in their declared order: one change, one reason.
    @Test func theReasonIsTheSameForTheSameChanges() {
        let changed = Self.opening {
            $0.build = "2.0 (1)"
            $0.screen = nil
        }
        #expect(WindowPictureStore.use(Self.meta(), for: changed, launch: Self.allowedLaunch) == .refuse(.screen))
        #expect(WindowPictureStore.use(Self.meta(), for: changed, launch: Self.facts { $0.recovered = true }) == .refuse(.crashRecovery))
        #expect(WindowPictureStore.use(Self.meta(), for: changed, launch: Self.facts {
            $0.recovered = true
            $0.savedPicture = false
        }) == .refuse(.settingOff))
    }

    /// A changed sidebar or pane tree refuses only its region; the rest of the picture shows.
    @Test func aChangedLayoutRefusesOnlyItsRegion() {
        let sidebar = Self.meta(workspaces: ["ws_a", "ws_b", "ws_c"])
        #expect(WindowPictureStore.use(Self.meta(), for: sidebar, launch: Self.allowedLaunch) == .show(stale: [.sidebar]))
        let panes = Self.meta(tree: .split(vertical: true, ratio: 0.5, a: .leaf("1"), b: .leaf("2")))
        #expect(WindowPictureStore.use(Self.meta(), for: panes, launch: Self.allowedLaunch) == .show(stale: [.pane]))
        let both = Self.meta(workspaces: ["ws_b", "ws_a"], tree: .leaf("2"))
        #expect(WindowPictureStore.use(Self.meta(), for: both, launch: Self.allowedLaunch) == .show(stale: [.sidebar, .pane]))
    }

    @Test func everyRefusalHasItsOwnMark() {
        let marks = WindowPictureStore.Refusal.allCases.map(\.mark)
        #expect(Set(marks).count == marks.count)
        #expect(marks.allSatisfy { $0.hasPrefix("launch_picture_refused.") })
    }

    /// The store hands out an allowed picture once; a refused one goes to nobody, is dropped and its reason marked.
    @Test func theStoreHandsOutOnlyAnAllowedPicture() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-picture-rules-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shot = WindowPictureStore.Shot(eligibility: .init(incognito: false, onScreen: true, onActiveSpace: true, fullScreen: false, hiddenFromCapture: false),
                                           base: try Self.image(color: CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
                                           size: CGSize(width: 8, height: 6), layers: [], fills: [],
                                           background: .init(red: 0, green: 0, blue: 0), meta: Self.meta())
        await WindowPictureStore(directory: directory, work: Self.work, encode: Self.png).save([shot])
        let front = WindowPictureStore.FrontWindow(window: Self.window, profile: "default")

        let allowed = WindowPictureStore(directory: directory, work: Self.work)
        allowed.prefetchFront({ front })
        _ = await allowed.frontFinished()
        let changedSidebar = Self.meta(workspaces: ["ws_a"])
        let shown = try #require(allowed.takeFront(matching: changedSidebar, launch: Self.allowedLaunch), "an allowed picture was not handed out")
        #expect(shown.stale == [.sidebar])
        #expect(shown.picture.windowID == Self.window)
        #expect(allowed.takeFront(matching: Self.meta(), launch: Self.allowedLaunch) == nil, "a picture was handed out twice")

        let refused = WindowPictureStore(directory: directory, work: Self.work)
        let (marks, mark) = AsyncStream.makeStream(of: String.self)
        refused.prefetchFront({ front }, mark: { mark.yield($0) })
        _ = await refused.frontFinished()
        #expect(refused.takeFront(matching: Self.opening { $0.theme = "other" }, launch: Self.allowedLaunch) == nil, "a picture of another theme was shown")
        #expect(refused.takeFront() == nil, "a refused picture was handed out later")
        refused.dropFront()
        mark.finish()
        var seen: [String] = []
        for await name in marks { seen.append(name) }
        #expect(seen == ["launch_picture_decoded", "launch_picture_refused.theme"], "the refusal was not marked, or the picture was reported dropped")
    }

    /// The read's end says only whether a picture exists; its pixels come out through the rules alone.
    @Test func theReadsEndGivesNoPicture() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-picture-rules-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        await WindowPictureStore(directory: directory, work: Self.work, encode: Self.png).save([try Self.shot()])
        let store = WindowPictureStore(directory: directory, work: Self.work)
        store.prefetchFront({ WindowPictureStore.FrontWindow(window: Self.window, profile: "default") })
        #expect(await store.frontFinished(), "the read found no picture")
        #expect(store.takeFront(matching: Self.meta(), launch: Self.facts { $0.recovered = true }) == nil, "a picture was shown after crash recovery")
        #expect(await store.frontFinished() == false, "a refused picture stayed to be handed out")
    }

    // MARK: The quit's save

    /// The quit keeps pictures only with the feature on and the setting read on; otherwise it deletes the last
    /// quit's and draws no window for them.
    @Test func theQuitKeepsPicturesOnlyWithTheFeatureAndTheSettingOn() async throws {
        let cases: [(featureOn: Bool, savedPicture: Bool?, keeps: Bool)] = [
            (true, true, true), (true, false, false), (true, nil, false), (false, true, false), (false, nil, false),
        ]
        for (featureOn, savedPicture, keeps) in cases {
            let directory = FileManager.default.temporaryDirectory.appending(path: "window-picture-quit-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = WindowPictureStore(directory: directory, work: Self.work, encode: Self.png)
            await store.save([try Self.shot()])
            try #require(FileManager.default.fileExists(atPath: directory.appending(path: "default/\(Self.window).json").path))
            var asked = false
            let shot = try Self.shot()
            await store.saveAtQuit(featureOn: featureOn, savedPicture: savedPicture) {
                asked = true
                return [shot]
            }
            let setting = savedPicture.map(String.init(describing:)) ?? "not loaded"
            let label = "feature \(featureOn), setting \(setting)"
            #expect(asked == keeps, "\(label): the windows were drawn for pictures nobody keeps")
            #expect(FileManager.default.fileExists(atPath: directory.path) == keeps, "\(label): the saved pictures were kept or lost wrongly")
        }
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

    /// Turning `launch.savedPicture` off deletes the saved pictures at once, with no quit; while the settings have not
    /// loaded, and with it on, they stay.
    @Test func turningTheSettingOffDeletesThePicturesWithNoQuit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-picture-setting-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WindowPictureStore(directory: directory, work: Self.work, encode: Self.png)
        await store.save([try Self.shot()])
        let setting = SavedPictureSetting()
        let follower = store.followSavedPicture({ setting.value }, on: MainWorkScheduler.testing { _ in nil })
        defer { follower.cancel() }

        setting.value = true
        let flushed = Date(timeIntervalSinceNow: 0.2)
        _ = Self.runMainLoop { Date() >= flushed }  // the change's flush runs (RunLoop.run is unavailable in async code)
        #expect(FileManager.default.fileExists(atPath: directory.path), "the pictures went while the setting was not loaded or on")

        setting.value = false
        #expect(Self.runMainLoop { !FileManager.default.fileExists(atPath: directory.path) }, "the pictures stayed on disk with the setting off")
    }

    static func shot() throws -> WindowPictureStore.Shot {
        WindowPictureStore.Shot(eligibility: .init(incognito: false, onScreen: true, onActiveSpace: true, fullScreen: false, hiddenFromCapture: false),
                                base: try image(color: CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
                                size: CGSize(width: 8, height: 6), layers: [], fills: [],
                                background: .init(red: 0, green: 0, blue: 0), meta: meta())
    }

    // MARK: Privacy fills

    /// A terminal holding Secure Input is filled even when the quit took its frame; without it the frame shows.
    @Test func secureInputFillsTheTerminal() throws {
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 6))
        let frame = try Self.image(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        guard case .fill(let filled) = WindowPictureStore.Pane.Content(.terminal(surface: surface, frame: frame, holdsSecureInput: true)) else {
            Issue.record("a Secure Input terminal was not filled")
            return
        }
        #expect(filled === surface)
        guard case .picture(_, let view) = WindowPictureStore.Pane.Content(.terminal(surface: surface, frame: frame, holdsSecureInput: false)) else {
            Issue.record("a terminal's frame was not shown")
            return
        }
        #expect(view === surface)
        guard case .drawn = WindowPictureStore.Pane.Content(.terminal(surface: surface, frame: nil, holdsSecureInput: false)) else {
            Issue.record("a terminal with no frame was not left to AppKit")
            return
        }
    }

    /// A withheld page (incognito, Secure Input, protected media, a capture-hidden window) is filled even when a
    /// picture of it exists, and so is a page the quit took no picture of.
    @Test func aWithheldOrUncapturedPageIsFilled() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 6))
        let picture = try Self.image(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let pageFrame = CGRect(x: 0, y: 2, width: 8, height: 4)
        guard case .fill(let withheld) = WindowPictureStore.Pane.Content(.browserPage(view, picture: picture, pageFrame: pageFrame, withheld: true)) else {
            Issue.record("a withheld page with a picture was not filled")
            return
        }
        #expect(withheld === view)
        guard case .fill = WindowPictureStore.Pane.Content(.browserPage(view, picture: nil, pageFrame: .zero, withheld: false)) else {
            Issue.record("a page with no picture was not filled")
            return
        }
        guard case .placed(_, let at) = WindowPictureStore.Pane.Content(.browserPage(view, picture: picture, pageFrame: pageFrame, withheld: false)) else {
            Issue.record("a page's picture was not placed")
            return
        }
        #expect(at == pageFrame)
    }

    /// The fill reaches the pixels: what a filled pane showed never reaches the composed picture.
    @Test func aFilledPaneLeavesNoneOfItsContentInThePicture() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 8, height: 6), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 6))
        window.contentView = root
        let area = NSView(frame: root.bounds)
        root.addSubview(area)
        window.orderFrontRegardless()
        let secret = try Self.image(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let pane = WindowPictureStore.Pane(key: "tab_a", area: area,
                                           content: .init(.terminal(surface: area, frame: secret, holdsSecureInput: true)))
        let facts = WindowPictureStore.Window(id: Self.window, profile: "default", incognito: false, theme: "t",
                                              background: .init(red: 0, green: 0, blue: 1), build: "1.0 (1)",
                                              layout: Self.meta().layout, screen: nil)
        let shot = try #require(WindowPictureStore.shot(of: window, root: root, backdrop: nil, sidebar: nil, panes: [pane], facts: facts))
        #expect(shot.layers.isEmpty, "a Secure Input terminal's frame was drawn")
        let picture = try #require(WindowPictureStore.compose(shot))
        let rep = NSBitmapImageRep(cgImage: picture)
        let center = try #require(rep.colorAt(x: picture.width / 2, y: picture.height / 2)?.usingColorSpace(.sRGB))
        #expect(center.blueComponent > 0.9 && center.redComponent < 0.1, "the pane is not the theme background")
    }
}
