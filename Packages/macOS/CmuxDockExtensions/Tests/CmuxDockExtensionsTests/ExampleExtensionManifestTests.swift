import Foundation
import Testing
@testable import CmuxDockExtensions

/// Keeps the in-repo example extension's manifest valid against the real
/// parser, so `Examples/extensions/hello-tui` always works as a `link` target
/// and as authoring documentation.
@Suite("Example extension manifest")
struct ExampleExtensionManifestTests {
    private var exampleDirectory: URL {
        // …/Packages/macOS/CmuxDockExtensions/Tests/CmuxDockExtensionsTests/<file>
        // → repo root is five directories up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/extensions/hello-tui", isDirectory: true)
    }

    @Test func helloTuiManifestParses() throws {
        let directory = exampleDirectory
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(DockExtensionManifest.manifestFileName).path
        ) else {
            // Standalone package checkouts don't carry the repo's Examples/.
            return
        }
        let manifest = try DockExtensionManifestLoader().load(fromDirectory: directory)
        #expect(manifest.id == "hello-tui")
        #expect(manifest.panes.count == 1)
        #expect(manifest.panes[0].command == ["./hello.sh"])
        #expect(manifest.unknownTopLevelKeys.isEmpty)
        #expect(manifest.appliesToCurrentPlatform)
    }
}
