import Foundation
import Testing
@testable import CMUXProjectModel

@Suite("XcconfigParser")
struct XcconfigParserTests {
    @Test
    func parsesSimpleAssignments() throws {
        let url = try writeTempXcconfig("""
        // header comment
        PRODUCT_BUNDLE_IDENTIFIER = ai.manaflow.cmux
        MACOSX_DEPLOYMENT_TARGET = 14.0
        EMPTY =
        """)
        let parsed = try XcconfigParser.parse(at: url)
        #expect(parsed["PRODUCT_BUNDLE_IDENTIFIER"] == "ai.manaflow.cmux")
        #expect(parsed["MACOSX_DEPLOYMENT_TARGET"] == "14.0")
        #expect(parsed["EMPTY"] == "")
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func stripsTrailingLineComments() throws {
        let url = try writeTempXcconfig("""
        SWIFT_VERSION = 6.0 // bumped 2026-05
        """)
        let parsed = try XcconfigParser.parse(at: url)
        #expect(parsed["SWIFT_VERSION"] == "6.0")
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func followsRelativeIncludes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseURL = dir.appendingPathComponent("Base.xcconfig")
        let derivedURL = dir.appendingPathComponent("Debug.xcconfig")
        try "PRODUCT_BUNDLE_IDENTIFIER = ai.manaflow.cmux\nMACOSX_DEPLOYMENT_TARGET = 14.0\n".write(to: baseURL, atomically: true, encoding: .utf8)
        try "#include \"Base.xcconfig\"\nMACOSX_DEPLOYMENT_TARGET = 15.0\n".write(to: derivedURL, atomically: true, encoding: .utf8)
        let parsed = try XcconfigParser.parse(at: derivedURL)
        #expect(parsed["PRODUCT_BUNDLE_IDENTIFIER"] == "ai.manaflow.cmux")
        #expect(parsed["MACOSX_DEPLOYMENT_TARGET"] == "15.0", "including file should override included")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test
    func optionalIncludeIsIgnoredWhenMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Top.xcconfig")
        try "#include? \"Missing.xcconfig\"\nKEY = value\n".write(to: url, atomically: true, encoding: .utf8)
        let parsed = try XcconfigParser.parse(at: url)
        #expect(parsed["KEY"] == "value")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test
    func parseChainMergesInDeclaredOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.xcconfig")
        let b = dir.appendingPathComponent("b.xcconfig")
        try "KEY = a\nA_ONLY = 1\n".write(to: a, atomically: true, encoding: .utf8)
        try "KEY = b\nB_ONLY = 2\n".write(to: b, atomically: true, encoding: .utf8)
        let merged = XcconfigParser.parseChain([a, b])
        #expect(merged["KEY"] == "b", "later file in chain wins")
        #expect(merged["A_ONLY"] == "1")
        #expect(merged["B_ONLY"] == "2")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test
    func cycleDetectionAvoidsInfiniteRecursion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.xcconfig")
        let b = dir.appendingPathComponent("b.xcconfig")
        try "#include \"b.xcconfig\"\nA = 1\n".write(to: a, atomically: true, encoding: .utf8)
        try "#include \"a.xcconfig\"\nB = 2\n".write(to: b, atomically: true, encoding: .utf8)
        let parsed = try XcconfigParser.parse(at: a)
        #expect(parsed["A"] == "1")
        #expect(parsed["B"] == "2")
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeTempXcconfig(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xcconfig")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
