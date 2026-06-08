import Foundation
import Testing
@testable import CmuxMobileDiffViewer

/// Behavioral coverage for the host-page generation and the custom-scheme
/// request-routing logic. These exercise the contract the React bundle and
/// WebKit depend on (the embedded config shape and the path→file/MIME mapping),
/// not source text.
struct DiffViewerHostHTMLTests {
    /// Decode the embedded `cmux-diff-viewer-config` JSON from a generated page.
    private func embeddedConfig(_ html: String) throws -> [String: Any] {
        let opening = "<script id=\"cmux-diff-viewer-config\" type=\"application/json\">"
        guard let startRange = html.range(of: opening) else {
            throw TestFailure("config script tag not found")
        }
        let afterOpen = html[startRange.upperBound...]
        guard let closeRange = afterOpen.range(of: "</script>") else {
            throw TestFailure("config script close tag not found")
        }
        let jsonText = String(afterOpen[..<closeRange.lowerBound])
            // Reverse the script-safety escaping the generator applies.
            .replacingOccurrences(of: "\\u003C", with: "<")
            .replacingOccurrences(of: "\\u003E", with: ">")
            .replacingOccurrences(of: "\\u0026", with: "&")
        let data = Data(jsonText.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure("config JSON is not an object")
        }
        return object
    }

    struct TestFailure: Error { let message: String; init(_ m: String) { message = m } }

    @Test func pageEmbedsConfigWithPatchAndAssetURLs() throws {
        let html = DiffViewerHostHTML.page(title: "My Workspace", sourceLabel: "git unstaged", prefersDark: true)
        let config = try embeddedConfig(html)

        let payload = try #require(config["payload"] as? [String: Any])
        // The bundle fetches the patch from this URL; it must be the relative
        // path the scheme handler serves the RPC patch at.
        #expect(payload["patchURL"] as? String == DiffViewerHostHTML.patchPath)
        #expect(payload["title"] as? String == "My Workspace")
        #expect(payload["sourceLabel"] as? String == "git unstaged")

        // The asset module URLs must match the bundled directory layout so the
        // worker, diff parser, and tree view all load.
        let assets = try #require(config["assets"] as? [String: Any])
        #expect(assets["diffsModuleURL"] as? String == DiffViewerHostHTML.diffsModuleURL)
        #expect(assets["treesModuleURL"] as? String == DiffViewerHostHTML.treesModuleURL)
        #expect(assets["workerPoolModuleURL"] as? String == DiffViewerHostHTML.workerPoolModuleURL)
        #expect(assets["workerModuleURL"] as? String == DiffViewerHostHTML.workerModuleURL)

        // The app entry module must be referenced by the page so the bundle boots.
        #expect(html.contains(DiffViewerHostHTML.appModuleURL))
    }

    @Test func pageOmitsSourceLabelWhenEmpty() throws {
        let html = DiffViewerHostHTML.page(title: "T", sourceLabel: nil, prefersDark: false)
        let config = try embeddedConfig(html)
        let payload = try #require(config["payload"] as? [String: Any])
        #expect(payload["sourceLabel"] == nil)
    }

    @Test func scriptLiteralEscapesScriptClose() {
        let literal = DiffViewerHostHTML.jsonScriptLiteral(["k": "</script><b>"])
        // A `</script>` inside the JSON must be escaped so it cannot close the
        // host script element early.
        #expect(!literal.contains("</script>"))
        #expect(literal.contains("\\u003C"))
    }
}
