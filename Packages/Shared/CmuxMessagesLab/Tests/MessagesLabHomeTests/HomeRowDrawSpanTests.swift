import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// A transcript row laid out narrower than where its content starts (a collapsed pane, a zero,
/// negative or NaN width in a layout pass) still has a drawable span. `RowDraw.drawSpan` built
/// `max(0, lower)...min(width, upper)`, which trapped with "Range requires lowerBound <=
/// upperBound" when `lower` passed the width: cmux NEXT nightly 4115843934401 died with SIGTRAP
/// in `RowCell.configureScoped` (https://github.com/manaflow-ai/cmux/issues/28977).
@MainActor @Suite struct HomeRowDrawSpanTests {
    /// Group rows: incoming bubbles with and without the avatar column, outgoing bubbles and names.
    static func rows() -> [RowSpec] {
        let s = HomeGroupSenderTests.self
        return s.rows(members: [s.me, s.alice, s.bob], authors: [s.alice, s.alice, s.bob, s.me, s.alice])
    }

    static let narrowWidths: [CGFloat] = [-200, -1, 0, 1, 10, 30, .nan, -.infinity]

    @Test(arguments: narrowWidths)
    func everyRowHasAnOrderedSpanAtANarrowWidth(width: CGFloat) {
        var specs = Self.rows()
        #expect(specs.contains { if case .part = $0.kind { true } else { false } })
        specs.append(RowSpec(key: "typing", kind: .typing, gap: 0, height: 20))
        specs.append(RowSpec(key: "receipt", kind: .receipt(bold: "Delivered", rest: ""), gap: 0, height: 14))
        for var spec in specs {
            spec.width = width
            let span = RowDraw.drawSpan(spec)
            #expect(span.lowerBound.isFinite && span.upperBound.isFinite, "row \(spec.key) at \(width): \(span)")
            #expect(span.lowerBound <= span.upperBound, "row \(spec.key) at \(width): \(span)")
        }
    }

    /// The rows the nightly drew when it crashed: incoming group bubbles whose span starts at the
    /// avatar column, at a width short of that column, render a transparent bitmap instead of trapping.
    @Test func aRowNarrowerThanItsBubbleStartRendersWithoutTrapping() throws {
        for var spec in Self.rows() {
            guard case let .part(p) = spec.kind else { continue }
            spec.width = 0
            let span = RowDraw.drawSpan(spec)
            #expect(span.upperBound - span.lowerBound == 0, "row \(spec.key) outgoing=\(p.outgoing): \(span)")
            _ = RowBitmaps.render(spec, scale: 2)
        }
    }

    /// At the normal width the span is unchanged: it starts left of the bubble and ends right of it.
    @Test func theSpanAtTheWindowWidthStillCoversTheBubble() {
        for spec in Self.rows() {
            guard case .part = spec.kind else { continue }
            let span = RowDraw.drawSpan(spec)
            let body = RowDraw.bodyRect(spec)
            #expect(span.lowerBound <= body.minX && span.upperBound >= body.maxX, "row \(spec.key): \(span) vs \(body)")
        }
    }
}
