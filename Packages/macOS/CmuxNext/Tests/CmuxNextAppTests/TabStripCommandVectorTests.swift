@testable import CmuxNextTabs
import Foundation
import Testing

/// Replays schemas/tab-strip-commands/vectors.json through ``TabStripModel``'s commands on its tabs (Cmd-W on a tab
/// that cannot close, Close Other Tabs / to the Left / to the Right, the tab they select, Move Tab Left / Right, Next /
/// Previous Tab), which ask the Rust rules (`tab_strip_*`, cmux-window-rules `tabs::strip`) over the app FFI. The
/// vectors were written from the Swift rules before they moved; cmux-layout-reducer-ffi's `tab_strip` test replays the
/// same file, so this proves the boundary in both directions.
@MainActor struct TabStripCommandVectorTests {
    struct Tab: Decodable {
        var id: String
        var pinned: Bool
        var closable: Bool
        var group: String?
    }

    struct KeyboardClose: Decodable, Equatable {
        var action: String
        var tab: String?
    }

    /// A string, an integer, a list of strings, a Cmd-W answer or null, as the probes mix them.
    enum Value: Decodable, Equatable {
        case none, text(String), number(Int), list([String]), close(KeyboardClose)

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .none } else if let number = try? value.decode(Int.self) { self = .number(number) }
            else if let text = try? value.decode(String.self) { self = .text(text) }
            else if let list = try? value.decode([String].self) { self = .list(list) }
            else { self = .close(try value.decode(KeyboardClose.self)) }
        }

        var text: String? { if case let .text(text) = self { text } else { nil } }
        var number: Int? { if case let .number(number) = self { number } else { nil } }
        var list: [String] { if case let .list(list) = self { list } else { [] } }
    }

    struct Case: Decodable {
        var tabs: [Tab]
        var collapsed: [String]
        var selected: String?
        var keyboardClose: [[Value]]
        var closedBy: [[Value]]
        var selectionKeeping: [[Value]]
        var moveIndex: [[Value]]
        var adjacent: [[Value]]
    }

    struct Vectors: Decodable {
        var v: Int
        var cases: [Case]
    }

    static func vectors() throws -> Vectors {
        // Tests/CmuxNextAppTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let file = url.appending(path: "schemas/tab-strip-commands/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }

    private func model(_ strip: Case) -> TabStripModel {
        let tabs = strip.tabs.map { tab in
            var item = TabItem(id: TabID(tab.id), title: tab.id)
            item.isPinned = tab.pinned
            item.isClosable = tab.closable
            item.groupID = tab.group.map { TabGroupID($0) }
            return item
        }
        let groups = Set(strip.tabs.compactMap(\.group)).sorted().map { TabGroupItem(id: TabGroupID($0), isCollapsed: strip.collapsed.contains($0)) }
        return TabStripModel(tabs: tabs, groups: groups, selectedID: strip.selected.map { TabID($0) })
    }

    @Test func everyCommandAnswersWhatTheSwiftRuleDid() throws {
        let vectors = try Self.vectors()
        #expect(vectors.v == 1)
        #expect(vectors.cases.count >= 100)
        for (number, strip) in vectors.cases.enumerated() {
            let model = model(strip)
            #expect(model.orderedTabs.map(\.id.rawValue) == strip.tabs.map(\.id), "strip \(number) is in display order")
            for probe in strip.keyboardClose {
                let id = TabID(try #require(probe[0].text))
                let want: TabKeyboardClose = switch probe[1] {
                case let .close(answer) where answer.action == "select": .select(TabID(answer.tab ?? ""))
                case let .close(answer) where answer.action == "ignore": .ignore
                default: .close
                }
                #expect(model.keyboardClose(id) == want, "strip \(number): Cmd-W \(id)")
            }
            for probe in strip.closedBy {
                let id = TabID(try #require(probe[0].text))
                #expect(model.closedByCloseOthers(keeping: id).map(\.rawValue) == probe[1].list, "strip \(number): others \(id)")
                #expect(model.closedByCloseToLeft(of: id).map(\.rawValue) == probe[2].list, "strip \(number): left \(id)")
                #expect(model.closedByCloseToRight(of: id).map(\.rawValue) == probe[3].list, "strip \(number): right \(id)")
            }
            for probe in strip.selectionKeeping {
                let id = TabID(try #require(probe[0].text))
                let kept = probe[1].list.map { TabID($0) }
                #expect(model.selectionKeeping(id, kept: kept)?.rawValue == probe[2].text, "strip \(number): keeping \(id)")
            }
            for probe in strip.moveIndex {
                let id = TabID(try #require(probe[0].text)), offset = try #require(probe[1].number)
                #expect(model.moveIndex(of: id, by: offset) == probe[2].number, "strip \(number): move \(id) \(offset)")
            }
            for probe in strip.adjacent {
                let id = probe[0].text.map { TabID($0) }, offset = try #require(probe[1].number)
                #expect(model.adjacentVisibleTab(from: id, offset: offset)?.rawValue == probe[2].text,
                        "strip \(number): step \(String(describing: id)) \(offset)")
            }
        }
    }
}
