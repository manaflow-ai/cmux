#if os(iOS)
@testable import CmuxAgentGUIUI
import CMUXMobileCore
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @Test func shippedTranscriptMountKeepsRenderedRowsInsideDisjointLayoutFrames() throws {
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        let container = UIViewController()
        container.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        container.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        controller.didMove(toParent: container)
        Self.pumpOverlapRunLoop()

        controller.apply(input: TranscriptProjectionInput(
            entries: Self.overlapFixtureEntries(),
            sessionPhase: .working
        ))
        controller.scrollToBottom(animated: false)
        Self.pumpOverlapRunLoop()

        #expect(controller.view.safeAreaInsets.top >= 59)
        #expect(controller.view.safeAreaInsets.bottom >= 34)
        let scale = max(window.screen.scale, 1)
        let tolerance = 0.5 / scale
        let cells = controller.collectionView.visibleCells.compactMap { $0 as? TranscriptCollectionCell }
        #expect(cells.count >= 4)

        var renderedRects: [(rowID: TranscriptRowID, rect: CGRect)] = []
        for cell in cells {
            let row = try #require(cell.row)
            let indexPath = try #require(controller.dataSource.indexPath(for: row.rowID))
            let attributes = try #require(controller.collectionView.layoutAttributesForItem(at: indexPath))
            let attributeRect = controller.collectionView.convert(attributes.frame, to: window).standardized
            let renderedRect = Self.renderedContentRect(of: cell, in: window).standardized
            let layoutHeight = controller.heightForRow(
                at: indexPath,
                width: controller.collectionView.bounds.width
            )

            #expect(abs(layoutHeight - attributes.frame.height) <= tolerance)
            #expect(renderedRect.minY >= attributeRect.minY - tolerance)
            #expect(renderedRect.maxY <= attributeRect.maxY + tolerance)
            renderedRects.append((row.rowID, renderedRect))
        }

        for firstIndex in renderedRects.indices {
            for secondIndex in renderedRects.indices where secondIndex > firstIndex {
                let first = renderedRects[firstIndex]
                let second = renderedRects[secondIndex]
                let intersection = first.rect.intersection(second.rect)
                #expect(
                    intersection.isNull || intersection.height <= tolerance,
                    "Rendered rows \(first.rowID) and \(second.rowID) overlap by \(intersection.height)pt"
                )
            }
        }
    }

    private static func overlapFixtureEntries() -> [EntrySnapshot] {
        let journalID = JournalID(rawValue: "row-overlap-regression")
        let payloads: [EntryPayload] = [
            .userMessage(UserMessagePayload(
                text: "Explain the rendering pipeline and verify every transition.",
                attachmentCount: 0,
                hasImage: false
            )),
            .toolRun(ToolRunPayload(
                toolName: "rg",
                argumentSummary: "Locate every transcript layout and rendering entry point",
                resultSummary: "Found the collection layout, hosting cell, and selectable text bridge",
                isTerminal: false,
                exitCode: 0,
                isRunning: false
            )),
            .agentProse(AgentProsePayload(markdown: Self.longAgentFixture)),
            .userMessage(UserMessagePayload(
                text: Self.longSingleLineUserFixture,
                attachmentCount: 0,
                hasImage: false
            )),
            .toolRun(ToolRunPayload(
                toolName: "swift test",
                argumentSummary: "Run the mounted transcript regression harness",
                resultSummary: nil,
                isTerminal: true,
                exitCode: nil,
                isRunning: true
            )),
            .agentProse(AgentProsePayload(markdown: Self.numberedListFixture)),
        ]
        return payloads.enumerated().map { offset, payload in
            let sequence = offset + 1
            return EntrySnapshot(
                journalID: journalID,
                seq: EntrySeq(rawValue: sequence),
                kind: payload.kind,
                content: EntryContent(contentHash: sequence, payload: payload),
                version: EntityVersion(rawValue: UInt64(sequence))
            )
        }
    }

    private static var longAgentFixture: String {
        """
        The transcript renderer receives immutable projected rows and places them in a bottom-origin collection layout. Each row needs one authoritative geometry calculation so selection, links, and activity affordances stay inside the cell assigned by the collection view.

        The previous path asked an offscreen SwiftUI host for a fitting height, then mounted a different host in the visible cell. Width proposals and text-container measurement could diverge, especially when prose wrapped across many lines or when adjacent bubbles used a relative width.

        This fixture intentionally spans well beyond twelve wrapped lines. It includes several paragraphs, punctuation, and enough varied word lengths to expose a one-line sizing disagreement instead of relying on a synthetic fixed-height view.
        """
    }

    private static var longSingleLineUserFixture: String {
        "Please keep this entire user request as one source line while making it long enough to wrap across at least three visual lines inside the trailing eighty-five-percent bubble, because its narrower proposal is one half of the original mismatch."
    }

    private static var numberedListFixture: String {
        """
        1. Measure the attributed prose with the same TextKit container used for rendering, including font leading and zero line-fragment padding.
        2. Derive every bubble, glyph, label, and button frame from the resulting deterministic layout value.
        3. Mount those frames directly in UIKit and confirm that no rendered descendant escapes the collection attribute frame.
        4. Update one streaming row without recomputing the other rows already cached for the same width and density.
        """
    }

    private static func renderedContentRect(of cell: TranscriptCollectionCell, in window: UIWindow) -> CGRect {
        let descendantRects = Self.renderedDescendantRects(in: cell.contentView, window: window)
        return descendantRects.reduce(CGRect.null) { $0.union($1) }
    }

    private static func renderedDescendantRects(in view: UIView, window: UIWindow) -> [CGRect] {
        let ownRect: [CGRect]
        if view !== view.superview,
           !view.isHidden,
           view.alpha > 0.01,
           view.bounds.width > 0,
           view.bounds.height > 0,
           Self.drawsVisibleContent(view) {
            ownRect = [view.convert(view.bounds, to: window).standardized]
        } else {
            ownRect = []
        }
        return ownRect + view.subviews.flatMap { Self.renderedDescendantRects(in: $0, window: window) }
    }

    private static func drawsVisibleContent(_ view: UIView) -> Bool {
        if view is UILabel || view is UITextView || view is UIImageView || view is UIButton {
            return true
        }
        if let color = view.backgroundColor, color.cgColor.alpha > 0.01 {
            return true
        }
        return view.layer.contents != nil || view.layer.borderWidth > 0 || view.layer.shadowOpacity > 0
    }

    private static func pumpOverlapRunLoop() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
#endif
