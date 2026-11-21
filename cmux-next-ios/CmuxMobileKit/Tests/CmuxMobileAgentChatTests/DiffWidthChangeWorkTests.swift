import Foundation
import Testing
@testable import CmuxMobileDiff
#if os(iOS)
import UIKit

/// A width step on a wrapped diff (rotation, Split View) measures only the rows near the screen;
/// the rest keep the heights they had as estimates and are measured as they come near, with the
/// reader's line held where it was. Counted at 1,000 and 10,000 lines: the rows measured per step
/// are the same at both, within 10% (offset writes may grow by the tree's depth, log n).
@MainActor
@Suite(.serialized) struct DiffWidthChangeWorkTests {
    /// Where the reader rests: a fixed distance from the top, so both sizes show the same lines.
    static let readerY: CGFloat = 12_000

    /// Every line added (one hunk, nothing collapsed); every fifth line long enough to wrap.
    static func file(lines: Int) -> DiffFile {
        let text = (0..<lines).map { n in
            n % 5 == 0 ? "        let value\(n) = " + String(repeating: "compute(\(n)) + ", count: 12) + "0" : "    let value\(n) = \(n)"
        }.joined(separator: "\n")
        return DiffFile(path: "x.swift", oldText: nil, newText: text)
    }

    /// The offset tree's depth for `n` rows.
    static func depth(_ n: Int) -> Int { Int(log2(Double(max(n, 2))).rounded(.up)) }

    static func key(_ file: DiffFile, width: CGFloat) -> DiffRenderKey {
        DiffRenderKey(fileID: file.id, contentHash: file.contentHash, options: DiffRows.Options(),
                      style: DiffRenderStyle(codeSize: 12, wrap: true, split: false, width: width))
    }

    struct Shown {
        let file: DiffFile
        let renderer: DiffRenderer
        let list: DiffCodeListController
        let window: UIWindow
    }

    /// The file's list in a 390 x 800 window, wrapped, the reader at `readerY`.
    static func shown(lines: Int) async throws -> Shown {
        let file = Self.file(lines: lines)
        let renderer = DiffRenderer()
        await renderer.update(file: file, key: Self.key(file, width: 390))
        let model = try #require(renderer.model)
        let list = DiffCodeListController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(list.collectionView)
        list.collectionView.frame = host.view.bounds
        list.apply(model)
        list.collectionView.layoutIfNeeded()
        list.collectionView.contentOffset.y = readerY
        list.collectionView.layoutIfNeeded()
        return Shown(file: file, renderer: renderer, list: list, window: window)
    }

    struct Step: CustomStringConvertible {
        var rows = 0
        var measured = 0
        var offsetWrites = 0
        var anchorMoved: CGFloat = 0
        var description: String {
            "rows \(rows): rows measured \(measured), offset writes \(offsetWrites), reader's line moved \(anchorMoved) pt"
        }
    }

    /// The row under the reader's top edge, and its distance from that edge.
    static func anchor(_ list: DiffCodeListController) throws -> (item: Int, screenTop: CGFloat) {
        let view = list.collectionView
        let top = view.contentOffset.y + view.adjustedContentInset.top
        let first = try #require(list.layout.layoutAttributesForElements(in: CGRect(x: 0, y: top, width: 1, height: 1))?.first)
        return (first.indexPath.item, first.frame.minY - view.contentOffset.y)
    }

    /// One width step, 390 to 430 pt, as the file screen makes it: the list takes the new bounds,
    /// then the model the renderer prepares for the new width.
    static func widthStep(lines: Int) async throws -> Step {
        let shown = try await Self.shown(lines: lines)
        defer { shown.window.isHidden = true }
        let view = shown.list.collectionView, layout = shown.list.layout
        let anchor = try Self.anchor(shown.list)
        let measured = layout.rowsMeasured, writes = layout.offsetWrites
        view.frame.size.width = 430
        view.layoutIfNeeded()
        await shown.renderer.update(file: shown.file, key: Self.key(shown.file, width: 430))
        let model = try #require(shown.renderer.model)
        shown.list.apply(model)
        view.layoutIfNeeded()
        var step = Step()
        step.rows = model.ids.count
        step.measured = model.heightsMade + layout.rowsMeasured - measured
        step.offsetWrites = layout.offsetWrites - writes
        let frame = try #require(layout.layoutAttributesForItem(at: IndexPath(item: anchor.item, section: 0))?.frame)
        step.anchorMoved = abs((frame.minY - view.contentOffset.y) - anchor.screenTop)
        return step
    }

    @Test func aWidthStepMeasuresOnlyTheRowsNearTheScreen() async throws {
        let small = try await Self.widthStep(lines: 1_000)
        let large = try await Self.widthStep(lines: 10_000)
        print("diff width step: \(small)")
        print("diff width step: \(large)")
        #expect(large.rows > 9 * small.rows, "\(small.rows) and \(large.rows) rows")
        for step in [small, large] {
            #expect(step.measured <= 300, "\(step)")
            #expect(step.anchorMoved <= 1, "\(step)")
        }
        #expect(Double(large.measured) <= Double(small.measured) * 1.1 + 2, "measured \(small.measured) at \(small.rows) rows, \(large.measured) at \(large.rows)")
        // Offsets: each measured row writes at most the tree's depth (log n), never a pass over the rows.
        for step in [small, large] {
            #expect(step.offsetWrites <= step.measured * (Self.depth(step.rows) + 1) + 2, "\(step)")
        }
    }

    /// Rows that come near after a width step take the heights a model made at that width gives
    /// them, and scrolling to them measures only the rows that came near.
    @Test func rowsComingIntoViewAfterAWidthStepTakeTheirHeightsAtTheNewWidth() async throws {
        let shown = try await Self.shown(lines: 2_000)
        defer { shown.window.isHidden = true }
        let view = shown.list.collectionView, layout = shown.list.layout
        view.frame.size.width = 430
        view.layoutIfNeeded()
        await shown.renderer.update(file: shown.file, key: Self.key(shown.file, width: 430))
        let model = try #require(shown.renderer.model)
        shown.list.apply(model)
        view.layoutIfNeeded()
        // One scroll step down: only the rows that came near are measured.
        let measured = layout.rowsMeasured
        view.contentOffset.y += 40
        view.layoutIfNeeded()
        #expect(layout.rowsMeasured - measured <= 20, "one 40 pt scroll step measured \(layout.rowsMeasured - measured) rows")
        // To the top, past every row laid out at the old width.
        view.contentOffset.y = -view.adjustedContentInset.top
        view.layoutIfNeeded()
        let exact = DiffRenderModel(rows: model.rows, key: Self.key(shown.file, width: 430))
        let shownRows = (layout.layoutAttributesForElements(in: view.bounds) ?? []).map(\.indexPath.item)
        #expect(!shownRows.isEmpty)
        for row in shownRows {
            let frame = try #require(layout.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame)
            #expect(abs(frame.height - exact.heights[row]) < 0.5, "row \(row) is \(frame.height) pt, at 430 pt it measures \(exact.heights[row])")
        }
        // Each row on screen sits right under the one above it.
        let frames = shownRows.sorted().compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        for (above, below) in zip(frames, frames.dropFirst()) {
            #expect(abs(above.maxY - below.minY) < 0.01)
        }
    }
}
#endif
