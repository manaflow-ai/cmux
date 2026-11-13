#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

/// DEBUG and bench builds only (`CMUX_BENCH_HOOKS`). The generated messages of a seeded
/// transcript (`HomeStore.debugSeed`): a fixed mix of the row kinds a pane-resize film must lay
/// out again at each width. A row depends on its index alone (no random, and no clock but the one
/// `epoch`), so two seeds of one size hold equal messages.
enum HomeSeedTranscript {
    /// What a row holds. Of every 10 rows: 6 text, 2 with a code fence, 1 tool row, 1 image.
    enum Kind: String, Sendable {
        case text, code, tool, image

        /// Row `index` (from 0): 3 and 7 of each 10 are code, 5 is a tool row, 9 is an image.
        init(index: Int) {
            switch index % 10 {
            case 3, 7: self = .code
            case 5: self = .tool
            case 9: self = .image
            default: self = .text
            }
        }
    }

    /// The time right after the newest row. Fixed, so every run shows the same times.
    static let epoch = Date(timeIntervalSince1970: 1_793_000_000)

    /// The image a row names when the caller prepared none (tests). No bytes are behind it.
    static let placeholderImage = AttachmentRef(hash: "seed-image", name: "Seed image.png", mimeType: "image/png",
                                                byteCount: 0, width: 1200, height: 900)

    /// How many of the first `count` rows are of each kind.
    static func kinds(count: Int) -> [Kind: Int] {
        var counts: [Kind: Int] = [:]
        for index in 0 ..< max(count, 0) { counts[Kind(index: index), default: 0] += 1 }
        return counts
    }

    /// Messages seq 1...`count` of `summary`'s conversation, oldest first.
    static func messages(count: Int, in summary: ConversationSummary, me: ParticipantID, image: AttachmentRef?,
                         epoch: Date) -> [Message] {
        (0 ..< max(count, 0)).map { message(index: $0, of: count, in: summary, me: me, image: image, epoch: epoch) }
    }

    /// Row `index` (from 0) of `count`: seq `index + 1`, written 47 s after the row before it, the
    /// newest one 47 s before `epoch`. Every 10th row is mine; the others are the conversation's
    /// Chief's (so their text is Markdown), or the first other participant's without a Chief.
    static func message(index: Int, of count: Int, in summary: ConversationSummary, me: ParticipantID,
                        image: AttachmentRef?, epoch: Date) -> Message {
        let mine = index % 10 == 0
        let others = summary.participants.filter { $0.id != me }
        let chief = (others.first(where: \.isChief) ?? others.first)?.id ?? me
        return Message(
            id: MessageID("msg_seed_\(index)"), conversation: summary.id, seq: Seq(max(index, 0)) + 1,
            clientMessageID: IdempotencyKey("seed_\(index)"), author: mine ? me : chief,
            parts: [part(index: index, mine: mine, image: image)],
            createdAt: epoch.addingTimeInterval(-Double(count - index) * 47)
        )
    }

    private static func part(index: Int, mine: Bool, image: AttachmentRef?) -> MessagePart {
        switch Kind(index: index) {
        case .text: return .text(mine ? myText(index) : chiefText(index))
        case .code: return .text(codeText(index))
        case .tool: return .work(work(index))
        case .image: return .attachment(image ?? placeholderImage)
        }
    }

    /// One short line of mine.
    private static func myText(_ index: Int) -> String {
        "\(myLines[index % myLines.count]) (\(index + 1))"
    }

    /// The Chief's Markdown: a sentence, then 0 to 5 list items. So a row is 1 to 6 lines, rows
    /// differ in height, and each wraps again at a new width.
    private static func chiefText(_ index: Int) -> String {
        let opener = "**Step \(index + 1).** \(chiefOpeners[index % chiefOpeners.count])"
        let items = (0 ..< (index % 6)).map { "- \(chiefItems[(index + $0) % chiefItems.count])" }
        return ([opener] + items).joined(separator: "\n")
    }

    /// The Chief's text with a fenced code block of 12 lines.
    private static func codeText(_ index: Int) -> String {
        let block = index % 10 == 3 ? swiftBlock : shellBlock
        return "Step \(index + 1): \(block.lead)\n\n```\(block.language)\n\(block.lines.joined(separator: "\n"))\n```"
    }

    /// A finished agent session the Chief started: the tool row. Its preview is what the row shows.
    private static func work(_ index: Int) -> WorkRef {
        let step = index / 10
        return WorkRef(session: "seed-session-\(index)", title: workTitles[step % workTitles.count], status: .done,
                       preview: "\(workPreviews[step % workPreviews.count]) (\(index + 1))")
    }

    private static let myLines = [
        "Status?",
        "Run the focused tests on CI.",
        "Looks good. Keep going.",
        "What is blocking the iOS archive?",
        "Ship the nightly after the checks pass.",
    ]

    private static let chiefOpeners = [
        "The fleet build of `feat-cmux-next` finished in 4 minutes 12 seconds, and the focused suites passed on the first run.",
        "Two tests failed on the base branch. They are not ours: [the base red](https://example.com/base-red) names the change that caused them.",
        "I opened a draft PR with the plan. _Want me to request a review?_",
        "The shell builds, sign-in works and Home draws its rows from the store. Three things remain before the nightly.",
        "Done. The device install passed the auth gate, and the app opened on the first try.",
    ]

    private static let chiefItems = [
        "Started three agents on the transport branch; two wait for a review and one runs the iOS archive now.",
        "The Mac is asleep, so the work continues on the team VM until it wakes.",
        "A person asked for variants. I prepared **two list densities** and a screenshot of each.",
        "`scripts/cmux-next/prepush-gate.py` refused one line; the fix is a checked index.",
        "The resize film shows no dropped frame at 50 rows. The run with 5000 rows comes next.",
        "Nothing waits for you. I will post the result when the last suite ends.",
        "The cache file is written once per idle second, off the main thread.",
    ]

    private static let workTitles = ["Transport review", "iOS archive", "Resize film", "Nightly notes"]

    private static let workPreviews = [
        "Reviewed the relay fallback: two findings, both small.",
        "Archived the iOS build and sent it to the device.",
        "Recorded the docked Home resize at three widths.",
        "Drafted the release notes from the merged changes.",
    ]

    private static let swiftBlock = (
        lead: "the width pass, as it is now.",
        language: "swift",
        lines: [
            "func setWidth(_ width: CGFloat) {",
            "    guard width != laidOutWidth else { return }",
            "    laidOutWidth = width",
            "    var top: CGFloat = 0",
            "    for index in rows.indices {",
            "        let height = rows[index].measure(width: width - insets.left - insets.right)",
            "        rows[index].frame = CGRect(x: insets.left, y: top, width: width, height: height)",
            "        top += height + rowSpacing",
            "    }",
            "    contentHeight = top",
            "    needsLayout = true",
            "}",
        ]
    )

    private static let shellBlock = (
        lead: "the commands that I ran.",
        language: "sh",
        lines: [
            "$ git fetch -q origin feat-cmux-next",
            "$ git rebase origin/feat-cmux-next",
            "Successfully rebased and updated refs/heads/perf/pane-resize.",
            "$ python3 scripts/cmux-next/prepush-gate.py",
            "app_lines        ok   (no rise)",
            "guardrails       ok   (0 new)",
            "crash_ratchet    ok   (0 new)",
            "pre-push: passed",
            "$ git push -q -u origin perf/pane-resize",
            "$ cmux-ci build cmux --ref HEAD --tag pane-resize-v1",
            "job 4821 queued on mac-3",
            "job 4821 passed in 4m 12s",
        ]
    )
}
#endif
