#if os(iOS)
@testable import CmuxAgentGUIUI
import CMUXMobileCore
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @Test func everyRowKindHasDeterministicMountedPixelRoundedLayout() {
        let widths: [CGFloat] = [320, 375, 393, 430]
        let densities = TranscriptDensity.allCases
        let scale: CGFloat = 3
        let theme = AgentGUITheme(terminalTheme: .monokai)
        var exercisedLayouts = 0
        let rows = Self.rowLayoutContentVariants.indices.flatMap(Self.layoutHarnessRows)
            + Self.supplementalLayoutHarnessRows

        for row in rows {
            for width in widths {
                for density in densities {
                    let first = TranscriptRowLayout.layout(
                        row: row,
                        width: width,
                        density: density,
                        scale: scale
                    )
                    let second = TranscriptRowLayout.layout(
                        row: row,
                        width: width,
                        density: density,
                        scale: scale
                    )
                    let spacing = TranscriptRowSpacing.resolved(for: [row], density: density)[row.rowID]
                        ?? TranscriptRowSpacing(top: 0, bottom: 0, density: density)
                    let cell = TranscriptCollectionCell(frame: CGRect(
                        x: 0,
                        y: 0,
                        width: width,
                        height: first.height
                    ))
                    cell.configure(
                        row: row,
                        spacing: spacing,
                        layout: first,
                        theme: theme,
                        answeringAskID: nil,
                        failedAskID: nil,
                        onShowActivity: { _ in },
                        onAnswer: { _, _ in },
                        onShowTerminal: {}
                    )
                    cell.layoutIfNeeded()
                    cell.contentView.layoutIfNeeded()
                    let mountedTextViews = Self.descendants(of: cell.contentView).compactMap { $0 as? UITextView }
                    let mountedButtons = Self.descendants(of: cell.contentView).compactMap { $0 as? UIButton }

                    #expect(first.height == second.height)
                    #expect(first.elementFrames == second.elementFrames)
                    #expect(Self.frameBytes(first.elementFrames) == Self.frameBytes(second.elementFrames))
                    #expect(cell.rowLayoutResult?.height == first.height)
                    #expect(mountedTextViews.count == first.textElements.count)
                    for textView in mountedTextViews {
                        textView.layoutManager.ensureLayout(for: textView.textContainer)
                        let usedHeight = textView.layoutManager.usedRect(for: textView.textContainer).maxY
                        let requiredHeight = ceil(max(usedHeight, 1) * scale) / scale
                        #expect(
                            abs(requiredHeight - textView.frame.height) <= 1 / scale,
                            "Rendered TextKit height diverged for \(row.rowID)"
                        )
                    }
                    for button in mountedButtons {
                        button.layoutIfNeeded()
                        guard let titleLabel = button.titleLabel, !titleLabel.bounds.isEmpty else { continue }
                        let titleFrame = titleLabel.convert(titleLabel.bounds, to: button)
                        #expect(titleFrame.minX >= -1 / scale)
                        #expect(titleFrame.maxX <= button.bounds.maxX + 1 / scale)
                        #expect(titleFrame.minY >= -1 / scale)
                        #expect(titleFrame.maxY <= button.bounds.maxY + 1 / scale)
                    }
                    if case .pendingAsk(let ask) = row.rowKind,
                       ask.id == "wrapping-option",
                       let titleLabel = mountedButtons.first?.titleLabel {
                        #expect(titleLabel.bounds.height > titleLabel.font.lineHeight)
                    }
                    if case .streaming = row.rowKind {
                        #expect(abs((cell.contentView.subviews.first?.alpha ?? 1) - 0.82) < 0.001)
                    }
                    #expect(abs(first.height * scale - (first.height * scale).rounded()) < 0.000_001)
                    #expect(first.elementFrames.allSatisfy {
                        $0.minX >= -0.001
                            && $0.maxX <= width + 0.001
                            && $0.minY >= -0.001
                            && $0.maxY <= first.height + 0.001
                    })
                    exercisedLayouts += 1
                }
            }
        }
        #expect(exercisedLayouts == ((13 * 5) + 4) * 4 * 2)
    }

    @Test func pureRowLayoutRunsOffTheMainActor() async {
        let row = TranscriptRow(
            rowID: .dateHeader("off-main"),
            rowKind: .dateHeader(dayKey: "Off-main layout")
        )
        let result = await Task.detached {
            TranscriptRowLayout.layout(
                row: row,
                width: 393,
                density: .comfortable,
                scale: 3
            )
        }.value

        #expect(result.height > 0)
        #expect(!result.textElements.isEmpty)
    }

    @Test func preferredContentSizeChangeRelaysOutVisibleTextFrames() throws {
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        let container = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            controller.traitOverrides.preferredContentSizeCategory = .large
            window.isHidden = true
        }
        controller.traitOverrides.preferredContentSizeCategory = .large
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
        controller.apply(input: TranscriptProjectionInput(entries: [EntrySnapshot(
            journalID: JournalID(rawValue: "dynamic-type-layout"),
            seq: EntrySeq(rawValue: 1),
            kind: .agentProse,
            content: EntryContent(
                contentHash: 1,
                payload: .agentProse(AgentProsePayload(markdown: Self.rowLayoutContentVariants[1]))
            ),
            version: EntityVersion(rawValue: 1)
        )]))
        Self.pumpLayoutHarnessRunLoop()
        controller.collectionView.layoutIfNeeded()
        let initialCell = try #require(controller.collectionView.visibleCells.first as? TranscriptCollectionCell)
        let initialTextView = try #require(Self.descendants(of: initialCell.contentView).first { $0 is UITextView })
        let initialHeight = initialTextView.frame.height
        #expect(controller.traitCollection.preferredContentSizeCategory == .large)

        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let deadline = Date(timeIntervalSinceNow: 1)
        while Date() < deadline {
            Self.pumpLayoutHarnessRunLoop()
            controller.collectionView.layoutIfNeeded()
            guard let candidate = controller.collectionView.visibleCells.first as? TranscriptCollectionCell,
                  let textView = Self.descendants(of: candidate.contentView).first(where: { $0 is UITextView }),
                  textView.frame.height > initialHeight
            else {
                continue
            }
            break
        }

        let updatedCell = try #require(controller.collectionView.visibleCells.first as? TranscriptCollectionCell)
        let updatedTextView = try #require(Self.descendants(of: updatedCell.contentView).first { $0 is UITextView })
        #expect(controller.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        #expect(updatedTextView.frame.height > initialHeight)
        #expect(updatedCell.rowLayoutResult?.textElements.first?.frame.height == updatedTextView.frame.height)
    }

    @Test func agentMarkdownPreservesStructureCodeFontsAndLinks() throws {
        let row = TranscriptRow(
            rowID: .entry(journalID: JournalID(rawValue: "markdown"), seq: EntrySeq(rawValue: 1)),
            rowKind: .proseAgent(
                text: "# Heading\n\n1. **Bold** and *italic* with [link](https://cmux.dev).\n2. `inline` code\n\n```swift\nlet value = 42\n```",
                grouping: .single
            )
        )
        let result = TranscriptRowLayout.layout(
            row: row,
            width: 393,
            density: .comfortable,
            scale: 3
        )
        let text = try #require(result.textElements.first?.attributedText.value)
        let fullRange = NSRange(location: 0, length: text.length)
        var hasLink = false
        var hasInlineCode = false
        var hasCodeBlock = false
        var hasBold = false
        text.enumerateAttributes(in: fullRange) { attributes, _, _ in
            hasLink = hasLink || attributes[.link] != nil
            hasInlineCode = hasInlineCode || attributes[.transcriptInlineCode] != nil
            hasCodeBlock = hasCodeBlock || attributes[.transcriptCodeBlock] != nil
            if let font = attributes[.font] as? UIFont {
                hasBold = hasBold || font.fontDescriptor.symbolicTraits.contains(.traitBold)
            }
        }

        #expect(text.string.contains("1. "))
        #expect(text.string.contains("2. "))
        #expect(hasLink)
        #expect(hasInlineCode)
        #expect(hasCodeBlock)
        #expect(hasBold)
        let codeBackground = try #require(result.backgroundElements.first { $0.kind == .codeBlock })
        #expect(abs(codeBackground.frame.width - (393 - 48)) < 0.001)
    }

    @Test func sixHundredRowCacheRecomputesOnlyStreamingTail() async throws {
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        let container = UIViewController()
        container.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        container.addChild(controller)
        controller.view.frame = container.view.bounds
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        Self.pumpLayoutHarnessRunLoop()

        controller.resetLayoutComputationCount()
        let start = CACurrentMediaTime()
        controller.apply(input: TranscriptProjectionInput(entries: Self.perfEntries(tailRevision: 0)))
        controller.collectionView.layoutIfNeeded()
        let initialMilliseconds = (CACurrentMediaTime() - start) * 1_000
        let initialCount = controller.layoutComputationCount
        print(String(format: "transcript-layout-perf initial-600 %.3fms", initialMilliseconds))

        #expect(controller.currentRows.count == 600)
        #expect(initialCount <= 24)
        await Self.awaitInitialPaint(in: controller, expectedRowCount: 600)
        #expect(controller.heightCache.count == 600)
        #expect(controller.backgroundLayoutComputationCount == 600)
        controller.collectionView.setContentOffset(
            CGPoint(x: 0, y: -controller.collectionView.contentInset.top),
            animated: false
        )
        #expect(controller.collectionView.contentOffset.y == -controller.collectionView.contentInset.top)
        controller.scrollToBottom(animated: false)
        #expect(controller.collectionView.contentOffset == controller.bottomRestOffset)

        controller.apply(input: TranscriptProjectionInput(entries: Self.perfEntries(tailRevision: 1)))
        controller.collectionView.layoutIfNeeded()
        #expect(controller.layoutComputationCount - initialCount == 1)
        #expect(controller.heightCache.count == 600)
    }

    @Test func initialLayoutWidthMismatchReschedulesAndReachesFirstPaint() async {
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        let container = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        container.addChild(controller)
        controller.view.frame = container.view.bounds
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        Self.pumpLayoutHarnessRunLoop()

        controller.apply(input: TranscriptProjectionInput(entries: Self.perfEntries(tailRevision: 0)))
        controller.scrollToBottom(animated: false)
        controller.view.frame.size.width = 430
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Self.awaitInitialPaint(in: controller, expectedRowCount: 600)

        #expect(controller.dataSource.snapshot().itemIdentifiers.count == 600)
        #expect(controller.initialLayoutTask == nil)
        #expect(controller.initialLayoutBatchCount == 2)
        #expect(controller.collectionView.contentOffset == controller.bottomRestOffset)
    }

    @Test func repeatedStreamingAppliesReusePendingInitialBatchAndReachFirstPaint() async {
        let controller = TranscriptListViewController(theme: AgentGUITheme(terminalTheme: .monokai))
        let container = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        container.addChild(controller)
        controller.view.frame = container.view.bounds
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        Self.pumpLayoutHarnessRunLoop()

        for revision in 0...20 {
            controller.apply(input: TranscriptProjectionInput(
                entries: Self.perfEntries(tailRevision: revision)
            ))
        }
        await Self.awaitInitialPaint(in: controller, expectedRowCount: 600)

        #expect(controller.dataSource.snapshot().itemIdentifiers == controller.currentRows.map(\.rowID))
        #expect(controller.heightCache.count == 600)
        #expect(controller.initialLayoutTask == nil)
        #expect(controller.initialLayoutBatchCount <= 2)
        #expect(controller.backgroundLayoutComputationCount <= 601)
    }

    private static let rowLayoutContentVariants = [
        "Short text.",
        "A deliberately long source line that wraps repeatedly across narrow widths while preserving deterministic TextKit geometry for every supported transcript density and phone rail.",
        "First paragraph.\n\n\nSecond paragraph after blank runs.\nThird line.",
        "Emoji 👩🏽‍💻🚀 mixed with 日本語と中文 to exercise composed characters and CJK wrapping.",
        "# Heading\n\n1. **Bold list item** with `inline code`\n2. [Linked item](https://cmux.dev)\n\n```swift\nlet wrappedCode = \"This code block wraps without horizontal scrolling\"\n```",
    ]

    private static func layoutHarnessRows(variant: Int) -> [TranscriptRow] {
        let text = rowLayoutContentVariants[variant]
        let journal = JournalID(rawValue: "layout-harness-\(variant)")
        let turnID = TranscriptTurnID(
            journalID: journal,
            promptSeq: EntrySeq(rawValue: 1),
            segmentAnchorSeq: EntrySeq(rawValue: 1)
        )
        let range = EntryRange(lowerBound: EntrySeq(rawValue: 10), upperBound: EntrySeq(rawValue: 12))
        let ticketID = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(variant)")!
        let item = TranscriptActivityItem(
            id: .entry(journalID: journal, seq: EntrySeq(rawValue: 11)),
            kind: variant.isMultiple(of: 2) ? .tool : .command,
            summary: text,
            isRunning: variant == 1
        )
        let summary = TranscriptActivitySummary(
            editedFileCount: variant,
            readFileCount: 1,
            searchedCode: true,
            listedFiles: false,
            commandCount: 2,
            eventCount: 1,
            items: [item]
        )
        return [
            TranscriptRow(rowID: .entry(journalID: journal, seq: EntrySeq(rawValue: 1)), rowKind: .proseAgent(text: text, grouping: .single)),
            TranscriptRow(rowID: .entry(journalID: journal, seq: EntrySeq(rawValue: 2)), rowKind: .proseUser(text: text, ticketState: nil, grouping: .single)),
            TranscriptRow(rowID: .entry(journalID: journal, seq: EntrySeq(rawValue: 3)), rowKind: .status(code: .compacted, detail: text)),
            TranscriptRow(rowID: .dateHeader(text), rowKind: .dateHeader(dayKey: text)),
            TranscriptRow(rowID: .boundary, rowKind: .boundary),
            TranscriptRow(rowID: .hole(range), rowKind: .hole(range: range)),
            TranscriptRow(rowID: .pendingTicket(ticketID), rowKind: .pendingTicket(SendTicket(
                id: ticketID,
                sessionID: AgentSessionID(rawValue: "layout-session"),
                text: text,
                attachmentCount: 0,
                state: .queuedLocal,
                createdAt: variant
            ))),
            TranscriptRow(rowID: .pendingAsk("ask-\(variant)"), rowKind: .pendingAsk(PendingAsk(
                id: "ask-\(variant)",
                sessionID: AgentSessionID(rawValue: "layout-session"),
                kind: .question,
                promptSummary: text,
                options: [text, "Continue"],
                state: .active
            ))),
            TranscriptRow(rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: 4)), rowKind: .streaming(textTail: text)),
            TranscriptRow(rowID: .entry(journalID: journal, seq: EntrySeq(rawValue: 5)), rowKind: .genericActivity(TranscriptGenericActivity(kindLabel: "tool", summary: text))),
            TranscriptRow(rowID: .activitySummary(turnID), rowKind: .activitySummary(summary), turnID: turnID),
            TranscriptRow(rowID: item.id, rowKind: .activityItem(item), turnID: turnID),
            TranscriptRow(rowID: .entry(journalID: journal, seq: EntrySeq(rawValue: 13)), rowKind: .unsupported(rawKind: "future", summary: text)),
        ]
    }

    private static var supplementalLayoutHarnessRows: [TranscriptRow] {
        let journal = JournalID(rawValue: "layout-harness-supplemental")
        let emptySummary = TranscriptGenericActivity(kindLabel: "tool", summary: "")
        let wrappingOption = "Choose this deliberately long answer option whose title must wrap over several lines without painting outside the explicitly measured button frame."
        return [
            TranscriptRow(
                rowID: .entry(journalID: journal, seq: EntrySeq(rawValue: 1)),
                rowKind: .proseAgent(text: "", grouping: .single)
            ),
            TranscriptRow(
                rowID: .streaming(journalID: journal, afterSeq: EntrySeq(rawValue: 2)),
                rowKind: .streaming(textTail: "")
            ),
            TranscriptRow(
                rowID: .entry(journalID: journal, seq: EntrySeq(rawValue: 3)),
                rowKind: .genericActivity(emptySummary)
            ),
            TranscriptRow(
                rowID: .pendingAsk("wrapping-option"),
                rowKind: .pendingAsk(PendingAsk(
                    id: "wrapping-option",
                    sessionID: AgentSessionID(rawValue: "layout-session"),
                    kind: .question,
                    promptSummary: "Select one option.",
                    options: [wrappingOption],
                    state: .active
                ))
            ),
        ]
    }

    private static func perfEntries(tailRevision: Int) -> [EntrySnapshot] {
        let journal = JournalID(rawValue: "layout-perf")
        return (1...600).map { sequence in
            let payload: EntryPayload = sequence.isMultiple(of: 2)
                ? .agentProse(AgentProsePayload(markdown: "Answer \(sequence) revision \(sequence == 600 ? tailRevision : 0)."))
                : .userMessage(UserMessagePayload(text: "Prompt \(sequence)", attachmentCount: 0, hasImage: false))
            return EntrySnapshot(
                journalID: journal,
                seq: EntrySeq(rawValue: sequence),
                kind: payload.kind,
                content: EntryContent(contentHash: sequence * 10 + (sequence == 600 ? tailRevision : 0), payload: payload),
                version: EntityVersion(rawValue: UInt64(sequence * 10 + (sequence == 600 ? tailRevision : 0)))
            )
        }
    }

    private static func pumpLayoutHarnessRunLoop() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private static func awaitInitialPaint(
        in controller: TranscriptListViewController,
        expectedRowCount: Int
    ) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while controller.dataSource.snapshot().itemIdentifiers.count != expectedRowCount,
              let task = controller.initialLayoutTask,
              ContinuousClock.now < deadline {
            await task.value
        }
    }

    private static func frameBytes(_ frames: [CGRect]) -> [UInt8] {
        frames.withUnsafeBytes { Array($0) }
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(Self.descendants)
    }
}
#endif
