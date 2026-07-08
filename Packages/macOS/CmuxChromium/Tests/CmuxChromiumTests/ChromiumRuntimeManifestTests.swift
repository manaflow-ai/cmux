import Foundation
import Testing
@testable import CmuxChromium

struct ChromiumRuntimeManifestTests {
    @Test func decodesReleaseManifest() throws {
        let json = """
        {
          "chromiumSourceRepo": "https://github.com/manaflow-ai/chromium-src.git",
          "chromiumSourceRef": "cmux/owl-fresh-hardening",
          "chromiumSourceCommit": "66fc3593cef3a1956eac411c8830a4a5006f648c",
          "artifactRepo": "manaflow-ai/chromium",
          "artifactWorkflow": "Build OWL Chromium Runtime",
          "artifactRunId": "25919989672",
          "runnerName": "aws-m1-ultra-chromium-1",
          "gnOutDir": "out/owl-release",
          "ninjaTargets": ["content_shell", "owl_fresh_mojo_runtime"]
        }
        """
        let manifest = try ChromiumRuntimeManifest(data: Data(json.utf8))
        #expect(manifest.chromiumSourceCommit == "66fc3593cef3a1956eac411c8830a4a5006f648c")
        #expect(manifest.chromiumSourceRef == "cmux/owl-fresh-hardening")
        #expect(manifest.artifactRepo == "manaflow-ai/chromium")
    }

    @Test func toleratesMissingFields() throws {
        let manifest = try ChromiumRuntimeManifest(data: Data("{}".utf8))
        #expect(manifest.chromiumSourceCommit == nil)
    }
}
