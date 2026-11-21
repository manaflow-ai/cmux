import Foundation
@testable import CmuxNextPages
import Testing

/// The served web update (plans/cmux-next/web-ota.md): a scheme handler keeps its bundled root and
/// gets the same folder inside the active update; with none (or outside a registered bundle) it
/// serves the bundle, and a request during the launch check waits for it.
struct WebBundleOverlayTests {
    static let bundledPages = URL(fileURLWithPath: "/App.app/Contents/Resources/CmuxNextPages.bundle/pages", isDirectory: true)
    static let bundledPane = URL(fileURLWithPath: "/App.app/Contents/Resources/CmuxNextAgentPane.bundle/agent-pane", isDirectory: true)
    // Not a repository path, so ci-target-graph.py does not count it as a read of the real bundle.
    static let paneOutput = "fixture/agent-pane"
    static let tree = URL(fileURLWithPath: "/Support/web-updates/trees/abc", isDirectory: true)

    static func overlay() -> WebBundleOverlay {
        let overlay = WebBundleOverlay(bases: [.init(bundled: bundledPages.path, output: WebBundleOverlay.pagesOutput)])
        overlay.register(bundled: bundledPane, output: paneOutput)
        return overlay
    }

    @Test func withNoUpdateTheBundleIsServed() async {
        let overlay = Self.overlay()
        let settings = Self.bundledPages.appending(path: "settings", directoryHint: .isDirectory)
        #expect(await overlay.root(for: settings) == settings)
    }

    @Test func anActiveUpdateServesItsCopyOfTheSameFolder() async {
        let overlay = Self.overlay()
        #expect(overlay.activate(Self.tree))
        #expect(!overlay.activate(Self.tree))
        let settings = await overlay.root(for: Self.bundledPages.appending(path: "settings", directoryHint: .isDirectory))
        #expect(settings.path == Self.tree.path + "/" + WebBundleOverlay.pagesOutput + "/settings")
        #expect(await overlay.root(for: Self.bundledPane).path
            == Self.tree.path + "/" + Self.paneOutput)
        // A root no bundle registered (an app page's own folder) keeps its files.
        let other = URL(fileURLWithPath: "/Users/me/app-page", isDirectory: true)
        #expect(await overlay.root(for: other) == other)
        // A sibling whose name only starts like a registered folder is not inside it.
        let sibling = URL(fileURLWithPath: Self.bundledPages.path + "-old/settings", isDirectory: true)
        #expect(await overlay.root(for: sibling) == sibling)
        #expect(overlay.activate(nil))
        #expect(await overlay.root(for: Self.bundledPane) == Self.bundledPane)
    }

    @Test func anEscapingOutputIsNotRegistered() async {
        let overlay = WebBundleOverlay(bases: [])
        overlay.register(bundled: Self.bundledPane, output: "../../etc")
        overlay.activate(Self.tree)
        #expect(await overlay.root(for: Self.bundledPane) == Self.bundledPane)
    }

    @Test func aRequestDuringTheLaunchCheckWaitsForIt() async {
        let overlay = Self.overlay()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let tree = Self.tree
        overlay.load {
            for await _ in gate { break }
            return tree
        }
        // task-owner: the test's one waiting request
        let request = Task { await overlay.root(for: Self.bundledPane) }
        open.yield()
        open.finish()
        #expect(await request.value.path.hasPrefix(Self.tree.path + "/"))
    }

    /// A page keeps reading the update it loaded with after a newer one becomes active, so pages
    /// reload into it one at a time and none mixes two builds' chunks; a new page gets the newer one.
    @Test func aPageReadsTheUpdateItLoadedWithUntilItReloads() async {
        let overlay = Self.overlay()
        let newer = URL(fileURLWithPath: "/Support/web-updates/trees/def", isDirectory: true)
        let settings = Self.bundledPages.appending(path: "settings", directoryHint: .isDirectory)
        let open = NSObject(), fresh = NSObject(), gone = NSObject()
        var pins = WebBundlePins()
        overlay.activate(Self.tree)
        pins.pin(ObjectIdentifier(open), to: await overlay.current())
        pins.pin(ObjectIdentifier(gone), to: nil)
        overlay.activate(newer)
        #expect(await overlay.current() == newer.standardizedFileURL)
        // The open page still reads its own tree.
        let pinned = pins.tree(for: ObjectIdentifier(open)) ?? nil
        #expect(overlay.root(for: settings, tree: pinned).path
            == Self.tree.path + "/" + WebBundleOverlay.pagesOutput + "/settings")
        #expect(pins.isBehind(ObjectIdentifier(open), newer.standardizedFileURL))
        // A page with no request yet loads the newer one: it is not behind.
        #expect(pins.tree(for: ObjectIdentifier(fresh)) == nil)
        #expect(!pins.isBehind(ObjectIdentifier(fresh), newer.standardizedFileURL))
        // The older tree stays on disk while the open page reads it; a gone page keeps nothing.
        pins.keep([ObjectIdentifier(open)])
        #expect(pins.pinned == [Self.tree.standardizedFileURL])
        #expect(pins.tree(for: ObjectIdentifier(gone)) == nil)
        // It reloaded at its safe point.
        pins.pin(ObjectIdentifier(open), to: newer.standardizedFileURL)
        #expect(!pins.isBehind(ObjectIdentifier(open), newer.standardizedFileURL))
        #expect(pins.pinned == [newer.standardizedFileURL])
        // With no tree (the bundle) a request keeps its bundled root.
        #expect(overlay.root(for: settings, tree: nil) == settings)
    }
}
