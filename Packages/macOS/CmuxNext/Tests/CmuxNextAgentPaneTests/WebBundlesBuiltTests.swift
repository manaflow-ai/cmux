import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextPages

/// The web bundles are build output, not committed (cx-vn5): every build path
/// runs scripts/cmux-next/build-web-bundles.sh first, and the resource
/// directories hold only a placeholder until it has run. This fails with the
/// command to run when a test build skipped it, instead of a missing-page
/// failure somewhere else.
@MainActor
@Suite
struct WebBundlesBuiltTests {
    private static let hint = "the web bundles are not built; run scripts/cmux-next/build-web-bundles.sh before swift build/test"

    @Test
    func theAgentPaneAndThePagesAreBuilt() throws {
        let pane = try #require(AgentPaneView.bundledPage, "\(Self.hint) (agent-pane/index.html)")
        let paneDirectory = pane.deletingLastPathComponent()
        for file in ["pane.js", "highlight-worker.js", "locales/en.js"] {
            #expect(FileManager.default.fileExists(atPath: paneDirectory.appending(path: file).path),
                    "\(Self.hint) (agent-pane/\(file))")
        }

        let settings = try #require(
            PageSchemeHandler.bundledRoot(for: PageDescriptor(id: "cmux.settings", resource: "settings", namespaces: [])),
            "\(Self.hint) (pages/settings)")
        let pages = settings.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: pages.path)
            .filter { name in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: pages.appending(path: name).path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        #expect(!names.isEmpty, "\(Self.hint) (pages/)")
        for name in names {
            #expect(FileManager.default.fileExists(atPath: pages.appending(path: "\(name)/index.html").path),
                    "\(Self.hint) (pages/\(name)/index.html)")
        }
    }
}
