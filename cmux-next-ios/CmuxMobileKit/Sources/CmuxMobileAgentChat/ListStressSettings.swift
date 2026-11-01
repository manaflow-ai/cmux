// DEBUG and Demo builds only: the list scroll stress rig (verify/listperf/).
#if DEBUG
import Foundation

/// Launch settings for the list scroll rig, from the environment
/// (`SIMCTL_CHILD_<NAME>` on a simulator). The rig itself lives in CmuxMobileShell
/// (`ListStressRig`); the mock agent reads the two chat settings here.
/// - `CMUX_MOBILE_LIST_SCREEN`: the list to measure: `workspaces`, `tabs`, `chat`, `diff`,
///   `artifacts` (the chat's Files and Artifacts grid; each replayed turn names an image, a page and a PDF), `home`, or `feed`
///   (seeded by `CMUX_MOBILE_FEED_STRESS`, as a reference for the rebuilt Feed).
/// - `CMUX_MOBILE_LIST_COUNT=N`: rows to seed (workspaces, tabs) or replayed turns (chat, diff).
/// - `CMUX_MOBILE_LIST_LIVE_HZ=HZ`: live changes per second while scrolling (workspace activity).
/// - `CMUX_MOBILE_LIST_STREAM=1`: every prompt streams one long answer with no waits.
/// - `CMUX_MOBILE_LIST_SEND=1` (chat): type and send a prompt through the composer after the chat
///   opens (the mock's own turn, or the long answer with `LIST_STREAM=1`), as a person does.
/// - `CMUX_MOBILE_LIST_PASSES=N`: top to bottom and back N times at `CMUX_MOBILE_LIST_SPEED` pt/s
///   (default 2400), one frame-interval window per direction (needs `CMUX_MOBILE_FRAMELOG=1`).
/// - `CMUX_MOBILE_LIST_PAN=1`: pan sideways instead (the diff's unwrapped code), one window per
///   direction (`<screen>-right-N`, `<screen>-left-N`).
/// - `CMUX_MOBILE_LIST_WRAP=1`, `CMUX_MOBILE_LIST_SPLIT=1`: the diff screen wraps lines, or shows Split
///   (where the width allows it: an iPad). `CMUX_MOBILE_LIST_HOLD_X=PT` with `LIST_PASSES=0`: pans the
///   widest scroll view to PT and holds (screenshots of the pinned gutter).
/// - `CMUX_MOBILE_LIST_EXIT_WHEN_DONE=1`: exit after the last pass (the rig waits for the exit).
public struct ListStressSettings: Equatable, Sendable {
    public static let shared = ListStressSettings()

    public var screen: String?
    public var count: Int
    public var liveHz: Double?
    public var streams: Bool
    public var sends: Bool
    /// `CMUX_MOBILE_LIST_OPEN_DELAY=S`: seconds before a transcript opens (default 1), so `SAMPLE` catches the open.
    public var openDelay: Double
    public var passes: Int
    public var speed: Double
    public var settle: Double
    public var exitsWhenDone: Bool
    /// `CMUX_MOBILE_LIST_LARGE_DIFF=0`: no 2400-line file rewrite in the newest replayed turn
    /// (the chat without the diff screen's load).
    public var largeDiff: Bool
    public var pans: Bool
    public var wraps: Bool
    public var splits: Bool
    public var holdX: Double?
    public var holdY: Double?
    /// `CMUX_MOBILE_LIST_PLAIN_CARDS=agent,terminal,browser`: those tab kinds' grid cards
    /// draw a plain fill (the tabs case's per-kind card cost).
    public var plainCards: Set<String>
    /// `CMUX_MOBILE_LIST_NO_CARD_PICTURES=1`: agent cards are never drawn into pictures.
    public var noCardPictures: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        screen = environment["CMUX_MOBILE_LIST_SCREEN"]
        count = environment["CMUX_MOBILE_LIST_COUNT"].flatMap(Int.init) ?? 0
        liveHz = environment["CMUX_MOBILE_LIST_LIVE_HZ"].flatMap(Double.init)
        streams = environment["CMUX_MOBILE_LIST_STREAM"] == "1"
        sends = environment["CMUX_MOBILE_LIST_SEND"] == "1"
        openDelay = environment["CMUX_MOBILE_LIST_OPEN_DELAY"].flatMap(Double.init) ?? 1
        passes = environment["CMUX_MOBILE_LIST_PASSES"].flatMap(Int.init) ?? 2
        speed = environment["CMUX_MOBILE_LIST_SPEED"].flatMap(Double.init) ?? 2400
        settle = environment["CMUX_MOBILE_LIST_SETTLE"].flatMap(Double.init) ?? 4
        exitsWhenDone = environment["CMUX_MOBILE_LIST_EXIT_WHEN_DONE"] == "1"
        largeDiff = environment["CMUX_MOBILE_LIST_LARGE_DIFF"] != "0"
        pans = environment["CMUX_MOBILE_LIST_PAN"] == "1"
        wraps = environment["CMUX_MOBILE_LIST_WRAP"] == "1"
        splits = environment["CMUX_MOBILE_LIST_SPLIT"] == "1"
        holdX = environment["CMUX_MOBILE_LIST_HOLD_X"].flatMap(Double.init)
        holdY = environment["CMUX_MOBILE_LIST_HOLD_Y"].flatMap(Double.init)
        plainCards = Set((environment["CMUX_MOBILE_LIST_PLAIN_CARDS"] ?? "").split(separator: ",").map(String.init))
        noCardPictures = environment["CMUX_MOBILE_LIST_NO_CARD_PICTURES"] == "1"
    }

    /// Turns the mock agent replays as history: the chat and diff screens' load.
    public var historyTurns: Int {
        screen == "chat" || screen == "diff" || screen == "artifacts" ? count : 0
    }
}

/// Deterministic agent-shaped text for the rig's replayed turns.
enum MockStressContent {
    static let largeDiffLines = 2400

    static func prompt(_ index: Int) -> String {
        ["Make the dialer retry with backoff (#\(index))", "Why does the relay drop frames on cellular?",
         "Add tests for the transport switch", "Summarize what changed since yesterday"][index % 4]
    }

    static func thought(_ index: Int) -> String {
        "The dialer keeps one attempt in flight. Retrying with backoff means a timer per Mac, so I should check how LinkDialer schedules today (pass \(index))."
    }

    static func code(lines: Int, seed: Int, edited: Bool = false) -> String {
        (0..<lines).map { line in
            let changed = edited && (line + seed) % 7 == 0
            return changed
                ? "    let value\(line) = try await dialer.connect(mac: macs[\(line % 9)], timeout: .seconds(\(line % 5 + 2))) // retried"
                : "    let value\(line) = compute(\(line), seed: \(seed)) // keeps the frame header at 9 bytes"
        }.joined(separator: "\n")
    }

    static func testOutput(_ index: Int) -> String {
        (0..<24).map { "Test Case 'LinkDialerTests.testRetry\($0)' passed (0.0\($0 % 9)s)" }.joined(separator: "\n")
            + "\nExecuted 24 tests, with 0 failures in 0.41 (0.44) seconds (run \(index))"
    }

    /// The artifacts rig's files: a screenshot, a page and a PDF per turn (the mock source
    /// serves each by its name).
    static func artifacts(_ index: Int) -> String {
        "Wrote `build/run\(index)/terminal.png`, `build/run\(index)/report.html` and `build/run\(index)/summary.pdf`."
    }

    static func answer(_ index: Int) -> String {
        """
        **Done (#\(index)).** The dialer now retries with exponential backoff, capped at 30 s:

        ```swift
        func retryDelay(attempt: Int) -> Duration {
            .seconds(min(30, 1 << min(attempt, 5)))
        }
        ```

        | Case | Before | After |
        | --- | --- | --- |
        | Wi-Fi drop | gave up | retries 1, 2, 4 s |
        | Cellular | one try | retries until linked |

        - `LinkDialer` keeps one attempt in flight per Mac
        - 24 tests pass, including the new `testRetryCap`
        """
    }

    /// One long answer, streamed in 6-character chunks every 16 ms (about 375 characters a second).
    static let streamedAnswer: String = (0..<40).map { answer($0) }.joined(separator: "\n\n")
}
#endif
