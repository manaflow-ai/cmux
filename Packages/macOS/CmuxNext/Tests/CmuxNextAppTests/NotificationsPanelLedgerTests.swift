import CoreGraphics
import CmuxNextDaemon
@testable import CmuxNextNotifications
import Foundation
import Testing

/// The panel's row index under a ledger delta (`NotificationsPanelLedger`): each id's index, each row's top and the
/// unread count stay what a rebuild from the whole ledger gives, whichever side an insert, removal or resize updates.
struct NotificationsPanelLedgerTests {
    static func row(_ id: Int, age: Double, unread: Bool) -> NotificationsPanelRow {
        NotificationsPanelRow(id: "n\(id)", title: "t\(id)", subtitle: nil, body: "", level: .info, source: nil, workspaceTitle: nil,
                              createdAt: Date(timeIntervalSince1970: 1_000_000 - age), unread: unread, surface: nil, terminal: nil)
    }

    /// The ledger matches one rebuilt from `rows` and `heights`.
    func expectMatches(_ ledger: NotificationsPanelLedger, _ rows: [NotificationsPanelRow], _ heights: [CGFloat],
                       sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(ledger.rows.map(\.id) == rows.map(\.id), sourceLocation: sourceLocation)
        #expect(ledger.unreadCount == rows.filter(\.unread).count, sourceLocation: sourceLocation)
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            #expect(ledger.index(of: row.id) == index, sourceLocation: sourceLocation)
            #expect(abs(ledger.top(index) - y) < 0.001, "row \(index) top", sourceLocation: sourceLocation)
            #expect(abs(ledger.rowHeight(index) - heights[index]) < 0.001, sourceLocation: sourceLocation)
            y += heights[index]
        }
        #expect(abs(ledger.height - y) < 0.001, sourceLocation: sourceLocation)
    }

    @Test func aNewRowGoesOnTopAndAnEvictionLeavesTheBottom() {
        var rows = (0..<10).map { Self.row($0, age: Double($0), unread: $0.isMultiple(of: 2)) }
        var heights = rows.indices.map { CGFloat(20 + $0) }
        var ledger = NotificationsPanelLedger()
        ledger.replace(rows, heights: heights)
        let fresh = Self.row(99, age: -1, unread: true)
        #expect(ledger.insertionIndex(fresh) == 0)
        ledger.insert(fresh, at: 0, height: 33)
        rows.insert(fresh, at: 0); heights.insert(33, at: 0)
        ledger.remove(at: rows.count - 1)
        rows.removeLast(); heights.removeLast()
        expectMatches(ledger, rows, heights)
    }

    /// Random inserts, removals and changes anywhere, checked against a rebuild after each.
    @Test(arguments: [1, 2, 3]) func everyEditMatchesARebuild(seed: UInt64) {
        var random = SeededRandom(seed)
        var rows = (0..<40).map { Self.row($0, age: Double($0 * 10), unread: $0.isMultiple(of: 3)) }
        var heights = rows.map { _ in CGFloat(Int.random(in: 18...60, using: &random)) }
        var ledger = NotificationsPanelLedger()
        ledger.replace(rows, heights: heights)
        var next = 100
        for _ in 0..<300 {
            let height = CGFloat(Int.random(in: 18...60, using: &random))
            switch Int.random(in: 0..<3, using: &random) {
            case 0:
                let row = Self.row(next, age: Double(Int.random(in: -10...500, using: &random)) + 0.5, unread: Bool.random(using: &random))
                next += 1
                let index = ledger.insertionIndex(row)
                #expect(index == rows.firstIndex { $0.createdAt <= row.createdAt } ?? rows.count)
                ledger.insert(row, at: index, height: height)
                rows.insert(row, at: index); heights.insert(height, at: index)
            case 1 where !rows.isEmpty:
                let index = Int.random(in: 0..<rows.count, using: &random)
                ledger.remove(at: index)
                rows.remove(at: index); heights.remove(at: index)
            default:
                guard !rows.isEmpty else { continue }
                let index = Int.random(in: 0..<rows.count, using: &random)
                let old = rows[index]
                let row = NotificationsPanelRow(id: old.id, title: old.title, subtitle: nil, body: "", level: .info, source: nil,
                                                workspaceTitle: nil, createdAt: old.createdAt, unread: !old.unread, surface: nil, terminal: nil)
                ledger.update(at: index, row, height: height)
                rows[index] = row; heights[index] = height
            }
            expectMatches(ledger, rows, heights)
        }
    }
}

/// A repeatable generator (SplitMix64), so a failure names its seed.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
