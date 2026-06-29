import CmuxAgentChat
import Foundation

/// The named fixture transcripts the lab can boot into, each targeting a
/// distinct failure mode for the message list and composer. Selected at launch
/// by `CMUX_CHAT_FIXTURE`; defaults to ``wrapping``.
///
/// This type is platform-agnostic on purpose: it builds plain `ChatMessage`
/// values so it unit-tests on the macOS host without UIKit.
public enum ChatLabFixture: String, CaseIterable, Sendable {
    /// A handful of one-line messages. Baseline for screenshots.
    case short
    /// Long wrapping paragraphs, mixed sender, to stress bubble sizing.
    case wrapping
    /// Fenced code blocks with horizontal overflow (agent chat is code-heavy).
    case code
    /// 20 messages timestamped within one second, to stress insert animation
    /// and autoscroll.
    case burst
    /// 10,000 messages, for scroll performance and memory.
    case history10k = "history-10k"
    /// A window smaller than the backlog so older pages must be prepended,
    /// proving jump-free anchoring.
    case paginate
    /// Emoji, CJK, RTL, and combining marks.
    case unicode
    /// Typing indicator plus sending/sent/delivered/read presentation.
    case states
    /// Inline image bubbles, for async media loading and prefetch.
    case media

    /// Resolves a fixture from the launch environment, falling back to
    /// ``wrapping`` when the variable is absent or unrecognized.
    public static func resolve(_ raw: String?) -> ChatLabFixture {
        guard let raw, let fixture = ChatLabFixture(rawValue: raw) else { return .wrapping }
        return fixture
    }

    /// Human-readable title for the lab's nav bar.
    public var title: String {
        switch self {
        case .short: return "Short"
        case .wrapping: return "Wrapping"
        case .code: return "Code"
        case .burst: return "Burst"
        case .history10k: return "History 10k"
        case .paginate: return "Paginate"
        case .unicode: return "Unicode"
        case .states: return "States"
        case .media: return "Media"
        }
    }
}

/// A fully-built scenario: the scripted backlog plus the wiring knobs the lab
/// needs to construct a `ChatConversationStore`.
public struct ChatLabScenario: Sendable {
    public let descriptor: ChatSessionDescriptor
    public let backlog: [ChatMessage]
    /// Initial in-memory window cap. Small for ``ChatLabFixture/paginate`` so
    /// the backlog spills into pageable history; large otherwise.
    public let pageSize: Int
    public let maxWindowCount: Int
    /// Whether sends echo a canned agent reply (keeps the demo alive).
    public let replyToSends: Bool
    /// The presence state to seed (drives the typing indicator).
    public let agentState: ChatAgentState

    public init(
        descriptor: ChatSessionDescriptor,
        backlog: [ChatMessage],
        pageSize: Int,
        maxWindowCount: Int,
        replyToSends: Bool,
        agentState: ChatAgentState
    ) {
        self.descriptor = descriptor
        self.backlog = backlog
        self.pageSize = pageSize
        self.maxWindowCount = maxWindowCount
        self.replyToSends = replyToSends
        self.agentState = agentState
    }
}

extension ChatLabFixture {
    /// Sentinel host-path scheme the media renderer recognizes to synthesize a
    /// deterministic local image for a given seed (no network in fixtures).
    public static let mediaScheme = "lab-media"

    /// Builds the scenario. `now` anchors all timestamps so screenshots and
    /// tests are deterministic.
    public func scenario(now: Date) -> ChatLabScenario {
        var builder = TranscriptBuilder(start: now.addingTimeInterval(-Double(seedSpanSeconds)))
        build(into: &builder, now: now)
        let descriptor = ChatSessionDescriptor(
            id: "lab-\(rawValue)",
            agentKind: .claude,
            title: title,
            state: agentState
        )
        return ChatLabScenario(
            descriptor: descriptor,
            backlog: builder.messages,
            pageSize: self == .paginate ? 30 : 100,
            maxWindowCount: self == .paginate ? 30 : 600,
            replyToSends: true,
            agentState: agentState
        )
    }

    private var seedSpanSeconds: Int {
        switch self {
        case .burst: return 1
        case .history10k, .paginate: return 60 * 60 * 6
        default: return 60 * 20
        }
    }

    private var agentState: ChatAgentState {
        switch self {
        case .states, .burst: return .working(since: Date(timeIntervalSinceReferenceDate: 0))
        default: return .idle
        }
    }

    private func build(into builder: inout TranscriptBuilder, now: Date) {
        switch self {
        case .short:
            builder.add(.system, .status(ChatStatusTransition(event: .sessionStarted)))
            builder.add(.user, prose("Can you bump the version and tag a release?"))
            builder.add(.agent, prose("On it. Bumping the minor version now."))
            builder.add(.user, prose("thanks"))
            builder.add(.agent, prose("Done. Tagged v0.16.0 and pushed."))
            builder.add(.user, prose("did CI go green?"))
            builder.add(.agent, prose("All checks passed. The release workflow is building the DMG now."))
            builder.add(.user, prose("perfect"))
            builder.add(.agent, prose("Anything else before I close this out?"))
            builder.add(.user, prose("nope, that's it"))

        case .wrapping:
            builder.add(.system, .status(ChatStatusTransition(event: .sessionStarted)))
            builder.add(.user, prose(
                "The keyboard on the chat screen freezes halfway when I swipe it "
                + "down, then jumps to the bottom. It should follow my finger the "
                + "whole way. Can you figure out why and fix it properly?"
            ))
            builder.add(.agent, prose(
                "The composer is positioned from `keyboardWillChangeFrame`, but that "
                + "notification does not fire during an interactive dismiss drag, so "
                + "the bar has nothing to follow until the gesture ends. The fix is "
                + "to make the bar part of the keyboard itself (an input accessory "
                + "view) so the system moves it for free, frame for frame."
            ))
            builder.add(.user, prose("Makes sense. Is that how Messages and Telegram do it?"))
            builder.add(.agent, prose(
                "Yes. Messages uses an input accessory on a proxy responder; Telegram "
                + "computes one keyboard-offset scalar per frame and applies it to both "
                + "the composer and the message list in the same pass, so they can never "
                + "disagree. We are doing the same thing here."
            ))
            builder.add(.user, prose("Great. What about the list itself, does it need anything?"))
            builder.add(.agent, prose(
                "The list is an inverted collection view, so the newest message sits at "
                + "the visual bottom and stays pinned for free. As the keyboard moves we "
                + "only adjust its bottom inset, never its content offset mid-drag, which "
                + "is what was causing the jitter you saw earlier."
            ))
            builder.add(.user, prose("Nice. Can we also round the composer and use the new glass material?"))
            builder.add(.agent, prose(
                "Done. The input is a Liquid Glass capsule now (`UIGlassEffect` on iOS 26, "
                + "a thick material below that), with the send button tucked inside the "
                + "pill on the trailing edge."
            ))
            builder.add(.user, prose("And it grows when I type a long message like this one that runs onto several lines?"))
            builder.add(.agent, prose(
                "It does. The text view grows with its content up to a cap, then starts "
                + "scrolling internally, and the bar height drives the keyboard region so "
                + "the list inset tracks it exactly."
            ))
            builder.add(.user, prose("Perfect, ship it."))
            builder.add(.agent, prose("Running the tracking gate one more time, then it is ready for you to feel on device."))

        case .code:
            builder.add(.user, prose("Show me the growing text view height logic."))
            builder.add(.agent, prose(
                "Here is the core of it. Scrolling stays off while the view grows so it "
                + "has an intrinsic size, then flips on at the cap:\n\n"
                + "```swift\noverride var intrinsicContentSize: CGSize {\n"
                + "    let fitting = sizeThatFits(CGSize(width: bounds.width,\n"
                + "                                      height: .greatestFiniteMagnitude))\n"
                + "    let clamped = min(max(fitting.height, minHeight), maxHeight)\n"
                + "    isScrollEnabled = fitting.height > maxHeight\n"
                + "    return CGSize(width: UIView.noIntrinsicMetric, height: clamped)\n"
                + "}\n```\n\nCall `invalidateIntrinsicContentSize()` from `textViewDidChange`."
            ))
            builder.add(.user, prose("And how do you clamp it so it scrolls past a few lines?"))
            builder.add(.agent, prose(
                "Scrolling stays disabled while it grows, then flips on at the cap:\n\n"
                + "```swift\nlet result = GrowingTextHeightSolver.solve(\n"
                + "    fittingHeight: fitting,\n    minHeight: 38,\n    maxHeight: 140\n)\n"
                + "textView.isScrollEnabled = result.scrollEnabled\nheightConstraint.constant = result.height\n```"
            ))
            builder.add(.user, prose("got it, thanks"))

        case .burst:
            for index in 0..<20 {
                let role: ChatRole = index.isMultiple(of: 2) ? .user : .agent
                builder.add(role, prose("Burst message #\(index + 1)"), step: 0.04)
            }

        case .history10k:
            buildBulk(into: &builder, count: 10_000)

        case .paginate:
            buildBulk(into: &builder, count: 240)

        case .unicode:
            builder.add(.user, prose("emoji test 👍🏽👩‍👩‍👧‍👦🇯🇵🔥"))
            builder.add(.agent, prose("日本語のテキスト、絵文字、そして合字: é é 👨🏿‍🚀"))
            builder.add(.user, prose("RTL: مرحبا بالعالم שלום עולם"))
            builder.add(.agent, prose("Combining marks: a\u{0301}e\u{0302}i\u{0303}o\u{0304}u\u{0308}"))

        case .states:
            builder.add(.user, prose("Run the full test suite and tell me what fails."))
            builder.add(.agent, prose("Running it now."))

        case .media:
            builder.add(.user, prose("Here are the two screenshots of the bug."))
            builder.add(.user, attachment(seed: 1))
            builder.add(.user, attachment(seed: 2))
            builder.add(.agent, prose("Got them. The composer is clearly mid-screen in the first one."))
            builder.add(.agent, attachment(seed: 3))
        }
    }

    private func buildBulk(into builder: inout TranscriptBuilder, count: Int) {
        for index in 0..<count {
            let role: ChatRole = index.isMultiple(of: 3) == false ? .agent : .user
            let text: String
            if index.isMultiple(of: 17) {
                text = "Message \(index): a longer line that wraps across more than one "
                    + "row so the list has to size mixed-height cells while scrolling."
            } else {
                text = "Message \(index)"
            }
            builder.add(role, prose(text), step: 2)
        }
    }

    private func prose(_ text: String) -> ChatMessageKind { .prose(ChatProse(text: text)) }

    private func attachment(seed: Int) -> ChatMessageKind {
        .attachment(ChatAttachment(
            media: .image,
            displayName: "screenshot-\(seed).png",
            hostPath: "\(ChatLabFixture.mediaScheme):\(seed)"
        ))
    }
}

/// Minimal monotonic-seq, advancing-timestamp transcript builder.
struct TranscriptBuilder {
    private(set) var messages: [ChatMessage] = []
    private var seq = 0
    private var clock: Date

    init(start: Date) { clock = start }

    mutating func add(_ role: ChatRole, _ kind: ChatMessageKind, step: TimeInterval = 30) {
        clock = clock.addingTimeInterval(step)
        messages.append(ChatMessage(id: "lab-\(seq)", seq: seq, role: role, timestamp: clock, kind: kind))
        seq += 1
    }
}
