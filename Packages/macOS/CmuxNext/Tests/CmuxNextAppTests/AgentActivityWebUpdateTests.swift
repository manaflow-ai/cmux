@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextUpdater
@testable import CmuxNextWebUpdates
import Foundation
import Testing

/// A web update reaches the Agent Activity page (plans/cmux-next/web-ota.md): its files ship in
/// CmuxNextAgentActivity's bundle, apart from the pages folder, so the web updater names where they
/// sit inside an update (the root the app registered for `cmux.agent-activity`). Without it, the
/// page kept its bundled files after every update (#35998).
@MainActor
@Suite struct AgentActivityWebUpdateTests {
    @Test func theActivityPageReadsItsFolderInsideTheActiveUpdate() async throws {
        // As at launch: the page's root first (AppDelegate), then the web updater's folders, here
        // into an overlay of the test's own.
        let root = try #require(PageDescriptor.registerAgentActivityRoot())
        let overlay = WebBundleOverlay(bases: [])
        WebUpdates.registerBundledFolders(overlay, appResources: nil)
        // With no update active, the page reads its bundle.
        #expect(await overlay.root(for: root) == root)
        let tree = URL(fileURLWithPath: "/Support/web-updates/trees/abc", isDirectory: true)
        overlay.activate(tree)
        let served = await overlay.root(for: root)
        #expect(served.standardizedFileURL.path == tree.appending(path: WebUpdateTree.outputs[2]).standardizedFileURL.path)
    }
}
