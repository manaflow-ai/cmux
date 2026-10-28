import CmuxNextCompat
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextChiefViews

/// The Chief view gallery opens its page through the host it is given (the app's
/// `AppServices.webUI`), not the static `PageWebView(descriptor:routes:)` path, so the host knows
/// the page and lists it in its own registry.
@Suite(.serialized)
@MainActor
struct ChiefViewsPageHostTests {
    /// A root for the gallery's page when the generated page bundle is missing on the test runner.
    /// The first registration wins (`PageID.registerBundledRoot`) and the bundled directory, when
    /// present, is served before it, so this never moves a real page.
    private static let registeredRoot: Bool = {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chief-views-test-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<html><body></body></html>".utf8).write(to: directory.appending(path: "index.html"))) != nil
        else { return false }
        PageID.registerBundledRoot(directory, for: PageDescriptor.chiefViews.id)
        return true
    }()

    private static let noApp = ChiefViewsHost(workspaces: { [] }, machineName: { _ in nil }, openChat: { _ in },
                                              revealTab: { _ in false }, openURL: { _ in },
                                              mainWork: MainWorkScheduler(budget: MainFrameBudget()))

    @Test func thePageOpensThroughTheGivenHost() throws {
        try #require(Self.registeredRoot)
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: .testing())
        let view = try #require(ChiefViewsPage(host: Self.noApp, webUI: host).makeView())
        #expect(host.openPages.map(ObjectIdentifier.init) == [ObjectIdentifier(view)])
        #expect(host.registry.pages(id: PageDescriptor.chiefViews.id).contains { $0 === view })
        // The host's own registry, not the process-wide one the static forwarders fill.
        #expect(!PageRegistry.pages(id: PageDescriptor.chiefViews.id).contains { $0 === view })
        host.close(view)
        #expect(host.openPages.isEmpty)
    }
}
