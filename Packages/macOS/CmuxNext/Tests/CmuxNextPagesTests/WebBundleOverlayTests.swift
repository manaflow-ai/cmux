import Foundation
@testable import CmuxNextPages
import Testing

/// The served web update (plans/cmux-next/web-ota.md): a scheme handler keeps its bundled root and
/// gets the same folder inside the active update; with none (or outside a registered bundle) it
/// serves the bundle, and a request during the launch check waits for it.
struct WebBundleOverlayTests {
    static let bundledPages = URL(fileURLWithPath: "/App.app/Contents/Resources/CmuxNextPages.bundle/pages", isDirectory: true)
    static let bundledPane = URL(fileURLWithPath: "/App.app/Contents/Resources/CmuxNextAgentPane.bundle/agent-pane", isDirectory: true)
    static let tree = URL(fileURLWithPath: "/Support/web-updates/trees/abc", isDirectory: true)

    static func overlay() -> WebBundleOverlay {
        let overlay = WebBundleOverlay(bases: [.init(bundled: bundledPages.path, output: WebBundleOverlay.pagesOutput)])
        overlay.register(bundled: bundledPane, output: "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane")
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
            == Self.tree.path + "/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane")
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
        overlay.load {
            for await _ in gate { break }
            return Self.tree
        }
        // task-owner: the test's one waiting request
        let request = Task { await overlay.root(for: Self.bundledPane) }
        open.yield()
        open.finish()
        #expect(await request.value.path.hasPrefix(Self.tree.path + "/"))
    }
}
