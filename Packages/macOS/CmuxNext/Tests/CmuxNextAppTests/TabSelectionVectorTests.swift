import CmuxNextTabs
import Foundation
import Testing

/// Replays schemas/tab-selection/vectors.json through ``TabMultiSelection`` and
/// ``TabSelectionMove``, which ask the Rust rules (`tab_selection*`, cmux-window-rules
/// `tabs::selection`) over the app FFI. The vectors were written from the Swift rules before they
/// moved; cmux-layout-reducer-ffi's `tab_selection` test replays the same file, so this proves the
/// boundary in both directions.
struct TabSelectionVectorTests {
    struct Selection: Decodable, Equatable {
        var ids: [String]
        var anchor: String?
    }

    struct Want: Decodable {
        var selection: Selection
        var active: String?
    }

    struct Change: Decodable {
        var op: String
        var id: String?
        var click: String?
        var order: [String]?
        var active: String?
        var want: Want
    }

    struct Move: Decodable {
        var order: [String]
        var pinned: [String]
        var selection: [String]
        var index: Int
        var want: [String]
    }

    struct Walk: Decodable {
        struct Step: Decodable {
            var current: [String]
            /// `[id, index]` or null.
            var want: [Value]?
        }

        var target: [String]
        var walk: [Step]
    }

    /// A string or an integer of a `[id, index]` pair.
    enum Value: Decodable {
        case text(String), number(Int)

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Int.self) { self = .number(number) } else { self = .text(try value.decode(String.self)) }
        }
    }

    struct Vectors: Decodable {
        var v: Int
        var clicks: [[Change]]
        var moves: [Move]
        var steps: [Walk]
    }

    static func vectors() throws -> Vectors {
        // Tests/CmuxNextAppTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let file = url.appending(path: "schemas/tab-selection/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }

    static let clicks: [String: TabMultiSelection.Click] = ["plain": .plain, "toggle": .toggle, "range": .range, "addRange": .addRange]

    @Test func everyClickCloseAndActivationSelectsWhatTheSwiftRuleDid() throws {
        let vectors = try Self.vectors()
        #expect(vectors.v == 1)
        for (number, strip) in vectors.clicks.enumerated() {
            var selection = TabMultiSelection()
            for change in strip {
                switch change.op {
                case "click":
                    let id = try #require(change.id), click = try #require(change.click.flatMap { Self.clicks[$0] })
                    let order = try #require(change.order).map { TabID($0) }
                    let active = selection.click(TabID(id), click, order: order, active: change.active.map { TabID($0) })
                    #expect(active?.rawValue == change.want.active, "strip \(number): click \(id)")
                case "follow":
                    selection.follow(order: try #require(change.order).map { TabID($0) })
                default:
                    selection.activated(change.id.map { TabID($0) })
                }
                let got = Selection(ids: selection.ids.map(\.rawValue).sorted(), anchor: selection.anchor?.rawValue)
                #expect(got == change.want.selection, "strip \(number): \(change.op)")
            }
        }
    }

    @Test func everyMoveAndDropStepMatchesTheSwiftRule() throws {
        let vectors = try Self.vectors()
        for move in vectors.moves {
            let rule = TabSelectionMove(order: move.order.map { TabID($0) }, pinned: Set(move.pinned.map { TabID($0) }))
            #expect(rule.moving(Set(move.selection.map { TabID($0) }), to: move.index).map(\.rawValue) == move.want)
        }
        for walk in vectors.steps {
            for step in walk.walk {
                let got = TabSelectionMove.nextStep(from: step.current.map { TabID($0) }, toward: walk.target.map { TabID($0) })
                switch step.want {
                case let .some([.text(id), .number(index)]):
                    #expect(got?.id.rawValue == id && got?.index == index, "\(step.current) toward \(walk.target)")
                default:
                    #expect(got == nil, "\(step.current) toward \(walk.target)")
                }
            }
        }
    }
}
