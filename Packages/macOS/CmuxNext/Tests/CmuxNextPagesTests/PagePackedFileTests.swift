import Foundation
import CmuxNextCompat
@testable import CmuxNextPages
import Testing

/// Settings ships packed (CMUX-570, app size): its entry and the chunks only it loads are
/// `pages/__shared/<name>.js.deflate`, and the page handler serves them inflated on every open.
struct PagePackedFileTests {
    /// `export const settings = "packed by node";\n` as node's `deflateRawSync(level: 9)` writes it
    /// (pack-pages.mjs), so the format the builder writes is the one the app reads.
    static let nodeDeflated = "S60oyC8qUUjOzysuUShOLSnJzEsvVrBVUCpITM5OTVFIqlTIy09JVbLmAgA="

    @Test func inflatesWhatTheBuilderWrites() throws {
        let stored = try #require(Data(base64Encoded: Self.nodeDeflated))
        #expect(PagePackedFile.inflate(stored) == Data("export const settings = \"packed by node\";\n".utf8))
        #expect(PagePackedFile.inflate(Data([0xff, 0xff, 0xff, 0xff])) == nil)
    }

    @Test @MainActor func opensSettingsFromItsPackedFormColdThenWarm() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pages = temp.appendingPathComponent("pages", isDirectory: true)
        let root = pages.appendingPathComponent("settings", isDirectory: true)
        let shared = pages.appendingPathComponent("__shared", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data(#"<script type="module">import "../__shared/page-settings.js";</script>"#.utf8)
            .write(to: root.appendingPathComponent("index.html"))
        // About the size of the real Settings entry (pack-pages.mjs's page-settings.js).
        var source = ""
        for line in 0..<40_000 { source += "export const row\(line) = { id: \(line), label: \"Setting \(line)\" };\n" }
        let entry = Data(source.utf8)
        let packed = try (entry as NSData).compressed(using: .zlib) as Data
        try packed.write(to: shared.appendingPathComponent("page-settings.js" + PagePackedFile.suffix))
        try #require(Data(base64Encoded: Self.nodeDeflated))
            .write(to: shared.appendingPathComponent("chunk-settings.js" + PagePackedFile.suffix))
        #expect(!FileManager.default.fileExists(atPath: shared.appendingPathComponent("page-settings.js").path))

        let handler = PageSchemeHandler(page: .settings, root: root, devServer: nil)
        handler.liveOverride = { .init(server: nil, overlay: nil) }
        let document = try #require(URL(string: "cmux-page://cmux.settings/index.html"))
        let entryURL = try #require(URL(string: "cmux-page://cmux.settings/__shared/page-settings.js"))
        let chunkURL = try #require(URL(string: "cmux-page://cmux.settings/__shared/chunk-settings.js"))

        let clock = ContinuousClock()
        let coldStart = clock.now
        let page = try #require(await handler.reply(to: document))
        let cold = try #require(await handler.reply(to: entryURL))
        let chunk = try #require(await handler.reply(to: chunkURL))
        let coldTime = clock.now - coldStart
        #expect(String(decoding: page.body, as: UTF8.self).contains("../__shared/page-settings.js"))
        #expect(cold.body == entry)
        #expect(cold.response.value(forHTTPHeaderField: "Content-Type") == "text/javascript")
        #expect(chunk.body == Data("export const settings = \"packed by node\";\n".utf8))

        // Warm: the second open inflates the same bytes again, from a packed copy the system has read.
        let warmStart = clock.now
        let warm = try #require(await handler.reply(to: entryURL))
        let warmTime = clock.now - warmStart
        #expect(warm.body == entry)
        print("PagePackedFileTests: Settings entry \(entry.count) bytes, packed \(packed.count); "
            + "cold open \(coldTime), warm \(warmTime)")

        // A file with neither form is still a 404, and a copy that does not inflate is never served.
        let missing = try #require(URL(string: "cmux-page://cmux.settings/__shared/missing.js"))
        #expect(await handler.reply(to: missing)?.response.statusCode != 200)
        try Data([0xff, 0xff, 0xff, 0xff]).write(to: shared.appendingPathComponent("broken.js" + PagePackedFile.suffix))
        let broken = try #require(URL(string: "cmux-page://cmux.settings/__shared/broken.js"))
        #expect(await handler.reply(to: broken)?.response.statusCode != 200)
    }
}
