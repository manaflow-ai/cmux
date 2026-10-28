import CmuxNextAgentPane
import CmuxNextPages
import Foundation

/// The one agent page every agent pane in this test target shows (every pane is on
/// the page host). The page host serves the agent page from one root per process, the first one
/// registered (`PageID.registerBundledRoot`), and a whole-target run makes panes from many suites in
/// one process, some through `AppServices` with the bundled page. So this is that root when one is
/// registered, else the bundled page, else a fixture page with a text field; never deleted.
enum AgentPageAppTestRoot {
    /// The agent page's `index.html`.
    static let page: URL? = {
        if let registered = PageID.bundledRoot(for: PageDescriptor.agent.id) { return registered.appending(path: "index.html") }
        if let bundled = AgentPaneView.bundledPage { return bundled }
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-page-app-test-\(UUID().uuidString)")
        let file = directory.appending(path: "index.html")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<html><body><input></body></html>".utf8).write(to: file)) != nil else { return nil }
        return file
    }()

    /// The environment that gives an `AgentTabStore` this page (`AgentPaneSource.rootVariable`, read
    /// in Debug builds), so it makes views when the bundle has no agent page.
    static var environment: [String: String] {
        page.map { [AgentPaneSource.rootVariable: $0.deletingLastPathComponent().path] } ?? [:]
    }
}
