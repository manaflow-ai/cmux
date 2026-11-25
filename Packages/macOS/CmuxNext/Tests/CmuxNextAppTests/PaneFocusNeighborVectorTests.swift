import CmuxNextLayout
import CoreGraphics
import Foundation
import Testing

/// Replays schemas/pane-focus-neighbor/vectors.json through ``FocusNavigation/neighbor(of:direction:frames:recency:columns:)``,
/// which asks the Rust rule (`layout_pane_neighbor`, cmux-layout-reducer `pane_focus`) over the app FFI. The vectors
/// were written from the Swift rule before it moved; cmux-layout-reducer-ffi's `pane_focus_neighbor` replays the same
/// file, so this proves the boundary in both directions.
struct PaneFocusNeighborVectorTests {
    struct Layout: Decodable {
        var frames: [String: [Double]]
        var recency: [String]
        var columns: [[String]]
        /// `[pane, direction, neighbor or null]`.
        var moves: [[String?]]
    }

    struct Vectors: Decodable {
        var v: Int
        var cases: [Layout]
    }

    static func vectors() throws -> Vectors {
        // Tests/CmuxNextAppTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let file = url.appending(path: "schemas/pane-focus-neighbor/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }

    static let directions: [String: LayoutDirection] = ["left": .left, "right": .right, "up": .up, "down": .down]

    @Test func everyFocusKeyLandsWhereTheSwiftRuleDid() throws {
        let vectors = try Self.vectors()
        #expect(vectors.v == 1)
        #expect(vectors.cases.count >= 150)
        for (number, layout) in vectors.cases.enumerated() {
            let frames = Dictionary(uniqueKeysWithValues: layout.frames.map { id, rect in
                (PaneID(id), CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]))
            })
            for move in layout.moves {
                let pane = try #require(move[0]), direction = try #require(move[1].flatMap { Self.directions[$0] })
                let got = FocusNavigation.neighbor(of: PaneID(pane), direction: direction, frames: frames,
                                                   recency: layout.recency.map { PaneID($0) },
                                                   columns: layout.columns.map { $0.map { PaneID($0) } })
                #expect(got?.rawValue == move[2], "layout \(number): \(pane) \(direction)")
            }
        }
    }
}
