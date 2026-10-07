import Foundation
import Testing
@testable import CmuxNextBrowser

/// The shared vectors that the Swift and C++ (shim) copies of the local file
/// handoff both pass: schemas/local-file-handoff/vectors.json.
@Suite struct LocalFileHandoffVectorTests {
    struct Vectors: Decodable {
        struct Case: Decodable { let url: String; let cef: Bool; let webkit: Bool }
        let cases: [Case]
    }

    static func vectors() throws -> Vectors {
        // Tests/CmuxNextBrowserTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let file = url.appending(path: "schemas/local-file-handoff/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }

    @Test func everySharedVectorAgrees() throws {
        let vectors = try Self.vectors()
        #expect(!vectors.cases.isEmpty)
        for item in vectors.cases {
            let url = try #require(URL(string: item.url), "\(item.url)")
            #expect(LocalFileHandoff.handsOff(url, engine: .cef) == item.cef, "cef \(item.url)")
            #expect(LocalFileHandoff.handsOff(url, engine: .webkit) == item.webkit, "webkit \(item.url)")
        }
    }

    /// Markdown opens the markdown page; the codecs CEF lacks open a WebKit tab.
    @Test func eachFileGoesWhereItShows() {
        #expect(LocalFileHandoff.target(for: URL(fileURLWithPath: "/r/README.md")) == .markdownPage)
        #expect(LocalFileHandoff.target(for: URL(fileURLWithPath: "/r/clip.mov")) == .webKitTab)
        #expect(LocalFileHandoff.target(for: URL(fileURLWithPath: "/r/clip.webm")) == nil)
        #expect(LocalFileHandoff.target(for: URL(string: "https://example.com/clip.mp4")!) == nil)
    }
}
