import Foundation
import Testing
@testable import CmuxNextDaemon

/// Rule L4 (plans/cmux-next/layer-ownership.md): the app's optimistic split (`ProvisionalSplit`)
/// is a Swift copy of the Rust reducer's `SplitNew`, so it must match the vectors the reducer
/// generates (`cmux-tui/crates/cmux-layout-reducer/fixtures/split_new_vectors.json`, checked for
/// drift by `split_new_vectors_match_the_fixture`): the pane order of the target's column after
/// the split.
@MainActor @Suite struct SplitParityTests {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            let column: [UInt64]
            let target: UInt64
            let direction: String
            let newPane: UInt64
            let expected: [UInt64]

            enum CodingKeys: String, CodingKey {
                case column, target, direction, expected
                case newPane = "new_pane"
            }
        }

        let cases: [Case]
    }

    private static func vectors() throws -> Vectors {
        // Tests/CmuxNextDaemonTests -> the repository root, five levels up from this directory.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "cmux-tui/crates/cmux-layout-reducer/fixtures/split_new_vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    /// A column's panes as the right-nested split chain cmux-tui builds for it.
    private static func chain(_ panes: [UInt64]) -> LayoutNode {
        guard let last = panes.last else { return .unknown }
        return panes.dropLast().reversed().reduce(LayoutNode.leaf(PaneID(rawValue: last))) { tail, pane in
            .split(id: nil, direction: .down, ratio: 0.5, a: .leaf(PaneID(rawValue: pane)), b: tail)
        }
    }

    @Test func theProvisionalSplitMatchesTheReducerVectors() throws {
        let vectors = try Self.vectors()
        #expect(!vectors.cases.isEmpty)
        for vector in vectors.cases {
            let direction: SplitDirection = vector.direction == "right" ? .right : .down
            let tree = try #require(ProvisionalSplit.split(Self.chain(vector.column), PaneID(rawValue: vector.target),
                                                          direction, 0.5, PaneID(rawValue: vector.newPane)))
            #expect(tree.paneIDs.map(\.rawValue) == vector.expected, "\(vector.column) split \(vector.target)")
        }
    }
}
