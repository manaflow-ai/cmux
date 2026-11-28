import Foundation
import Testing
@testable import CmuxAgentCursor

@Suite struct AgentCursorPaletteTests {
    @Test func sessionColorsMatchTheRustRenderer() throws {
        let url = try #require(Bundle.module.url(forResource: "palette_vectors", withExtension: "json", subdirectory: "Resources"))
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(doc["cases"] as? [[String: Any]])
        #expect(cases.count >= 14)
        for c in cases {
            let id = try #require(c["id"] as? String)
            let palette = AgentCursorPalette.forSession(id)
            #expect(palette.name == c["palette"] as? String, "\(id)")
            #expect(palette.cursorStart == (c["cursor_start"] as? [Int])?.map(UInt8.init), "\(id)")
            #expect(palette.cursorMid == (c["cursor_mid"] as? [Int])?.map(UInt8.init), "\(id)")
            #expect(palette.cursorEnd == (c["cursor_end"] as? [Int])?.map(UInt8.init), "\(id)")
            #expect(palette.bloomOuter == (c["bloom_outer"] as? [Int])?.map(UInt8.init), "\(id)")
            #expect(palette.bloomInner == (c["bloom_inner"] as? [Int])?.map(UInt8.init), "\(id)")
            let gradient = try #require(c["gradient"] as? [String: [Int]])
            for (t, want) in gradient {
                #expect(palette.gradient(at: try #require(Double(t))) == want.map(UInt8.init), "\(id) gradient(\(t))")
            }
        }
    }
}
