import Foundation
import Testing
@testable import CmuxNextSidebar

/// The shared sidebar-layout-v1 cases (Fixtures/sidebar-layout-cases.json),
/// which the cmux-tui-core state reducer also runs, so the two reducers and
/// the wire format cannot drift.
@Suite struct SidebarLayoutFixtureTests {
    private struct Case: Decodable {
        var name: String
        var op: SidebarLayoutOp
        var expect: String
        var reason: String?
        var revision: UInt64?
        var section: String?
        var items: [String]?
        var arrangement: SectionArrangement?
    }

    private struct File: Decodable { var cases: [Case] }

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/sidebar-layout-cases.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }

    @Test func everySharedCaseMatches() throws {
        let cases = try Self.cases()
        #expect(cases.count >= 20)
        for item in cases {
            let result = SidebarLayoutReducer.reduce(.defaults, item.op)
            switch (item.expect, result) {
            case ("accept", .success(let doc)):
                #expect(doc.revision == item.revision, "\(item.name)")
                if let id = item.section.map(LayoutSectionID.init) {
                    let section = try #require(doc.section(id), "\(item.name)")
                    if let items = item.items { #expect(section.items.map(\.id.rawValue) == items, "\(item.name)") }
                    if let arrangement = item.arrangement { #expect(section.arrangement == arrangement, "\(item.name)") }
                }
            case ("reject", .failure(let reject)):
                #expect(reject.rawValue == item.reason, "\(item.name)")
            default:
                Issue.record("\(item.name): expected \(item.expect), got \(result)")
            }
        }
    }
}
