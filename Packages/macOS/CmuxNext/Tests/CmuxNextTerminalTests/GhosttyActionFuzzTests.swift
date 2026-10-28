import CmuxFuzzSupport
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// The app's side of OSC parsing: Ghostty parses OSC 0/2 titles, OSC 7 folders,
/// OSC 8 links, OSC 9;4 progress and OSC 133 command ends from program output and hands each to
/// `action_cb`; ``GhosttyActionDecoder`` copies it out of C memory. Any tag and any payload a
/// program can make (invalid UTF-8, NUL, a huge title, out-of-range enums and numbers) decodes to
/// its value or to nothing, never a trap. Pointers stay valid (Ghostty's guarantee); every other
/// payload byte is random. Seeded property tests on CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS).
struct GhosttyActionFuzzTests {
    static let pieces: [[UInt8]] = [
        Array("file://host/Users/a b".utf8), Array("/tmp/x".utf8), Array("https://example.com/?q=1".utf8), Array("~".utf8),
        Array("title".utf8), Array("é".utf8), Array("🙂".utf8), Array("\u{202E}".utf8), Array("%00".utf8), Array(";".utf8),
        [0xC3], [0xE2, 0x82], [0xF0, 0x9F], [0xFF], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0x1B], [0x07], [0x00], [0x0A],
    ]

    /// Text bytes as a program writes them, now and then a very long run.
    static func text(_ rng: inout FuzzRNG) -> [UInt8] {
        var out: [UInt8] = []
        for _ in 0..<rng.below(10) { out += rng.element(of: pieces) ?? [] }
        if rng.oneIn(32) { out += [UInt8](repeating: UInt8(ascii: "a"), count: rng.below(70_000)) }
        return out
    }

    /// One input, replayed from bytes. Darwin only: the decoder needs GhosttyNextKit, so the Linux
    /// libFuzzer targets skip this suite; the seeded runs here are its fuzzing.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        try decodeOne(&rng)
    }

    static func decodeOne(_ rng: inout FuzzRNG) throws {
        var action = ghostty_action_s()
        action.tag = ghostty_action_tag_e(rawValue: numericCast(rng.below(80)))
        withUnsafeMutableBytes(of: &action.action) { union in
            for index in union.indices { union[index] = rng.byte() }
        }
        let bytes = text(&rng)
        let length = rng.below(bytes.count + 1)
        let isNil = rng.oneIn(8)
        let flag = rng.bool()
        let cString = bytes.map { CChar(bitPattern: $0) } + [0]
        let decoded: GhosttyAction? = cString.withUnsafeBufferPointer { buffer in
            let pointer = isNil ? nil : buffer.baseAddress
            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_WINDOW_TITLE: action.action.set_title.title = pointer
            case GHOSTTY_ACTION_SET_TAB_TITLE: action.action.set_tab_title.title = pointer
            case GHOSTTY_ACTION_PWD: action.action.pwd.pwd = pointer
            case GHOSTTY_ACTION_START_SEARCH: action.action.start_search.needle = pointer
            case GHOSTTY_ACTION_OPEN_URL:
                action.action.open_url.url = pointer
                action.action.open_url.len = numericCast(length)
            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                action.action.mouse_over_link.url = pointer
                action.action.mouse_over_link.len = numericCast(length)
            case GHOSTTY_ACTION_CONFIG_CHANGE: action.action.config_change.config = nil
            case GHOSTTY_ACTION_KEY_SEQUENCE: action.action.key_sequence.active = flag
            case GHOSTTY_ACTION_RELOAD_CONFIG: action.action.reload_config.soft = flag
            default: break
            }
            return GhosttyActionDecoder.decode(action)
        }
        // What String(cString:) reads: the bytes before the first NUL, invalid UTF-8 repaired.
        let cText = isNil ? "" : String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        let sized: String? = isNil || length == 0 ? nil : String(decoding: bytes.prefix(length), as: UTF8.self)
        let shown = "tag \(action.tag.rawValue), \(bytes.count) bytes, length \(length), nil \(isNil): \(String(describing: decoded))"
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            guard case .setTitle(let title)? = decoded else { return try FuzzRun.check(false, "no title: \(shown)") }
            try FuzzRun.check(title == cText, "title: \(shown)")
        case GHOSTTY_ACTION_SET_WINDOW_TITLE:
            guard case .host(.setWindowTitle(let title))? = decoded else { return try FuzzRun.check(false, "no window title: \(shown)") }
            try FuzzRun.check(title == cText, "window title: \(shown)")
        case GHOSTTY_ACTION_PWD:
            guard case .pwd(let pwd)? = decoded else { return try FuzzRun.check(false, "no pwd: \(shown)") }
            try FuzzRun.check(pwd == cText, "pwd: \(shown)")
        case GHOSTTY_ACTION_START_SEARCH:
            guard case .startSearch(let needle)? = decoded else { return try FuzzRun.check(false, "no search: \(shown)") }
            try FuzzRun.check(needle == cText, "needle: \(shown)")
        case GHOSTTY_ACTION_OPEN_URL:
            if let sized {
                guard case .openURL(let url)? = decoded else { return try FuzzRun.check(false, "no URL: \(shown)") }
                try FuzzRun.check(url == sized, "URL: \(shown)")
            } else {
                try FuzzRun.check(decoded == nil, "an empty URL opened: \(shown)")
            }
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard case .mouseOverLink(let link)? = decoded else { return try FuzzRun.check(false, "no hover: \(shown)") }
            try FuzzRun.check(link == sized, "hover link: \(shown)")
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            try FuzzRun.check(decoded == nil, "a nil config changed: \(shown)")
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            try checkProgress(action.action.progress_report, decoded, shown)
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let finished = action.action.command_finished
            guard case .commandFinished(let result)? = decoded else { return try FuzzRun.check(false, "no result: \(shown)") }
            try FuzzRun.check(result.exitCode == (finished.exit_code < 0 ? nil : Int(finished.exit_code)), "exit code: \(shown)")
            try FuzzRun.check(result.duration >= .zero && result.duration == .nanoseconds(Int64(clamping: finished.duration)),
                              "duration: \(shown)")
        default:
            break
        }
    }

    /// OSC 9;4: a known state gives its progress with the reported value (nil below 0), any other none.
    static func checkProgress(_ report: ghostty_action_progress_report_s, _ decoded: GhosttyAction?, _ shown: String) throws {
        guard case .progress(let progress)? = decoded else { return try FuzzRun.check(false, "no progress: \(shown)") }
        let value: Int? = report.progress < 0 ? nil : Int(report.progress)
        switch progress {
        case .normal(let reported)?:
            try FuzzRun.check(report.state == GHOSTTY_PROGRESS_STATE_SET && reported == value, "normal: \(shown)")
        case .error(let reported)?:
            try FuzzRun.check(report.state == GHOSTTY_PROGRESS_STATE_ERROR && reported == value, "error: \(shown)")
        case .paused(let reported)?:
            try FuzzRun.check(report.state == GHOSTTY_PROGRESS_STATE_PAUSE && reported == value, "paused: \(shown)")
        case .indeterminate?:
            try FuzzRun.check(report.state == GHOSTTY_PROGRESS_STATE_INDETERMINATE, "indeterminate: \(shown)")
        case nil:
            let known = [GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_ERROR, GHOSTTY_PROGRESS_STATE_PAUSE,
                         GHOSTTY_PROGRESS_STATE_INDETERMINATE]
            try FuzzRun.check(!known.contains(report.state), "a known state gave none: \(shown)")
        }
    }

    @Test func everyActionDecodesOrIsNothing() throws {
        try FuzzRun("GhosttyAction.decode", seed: 0x0_5C7_A11, iterations: 8_000).forEach { rng in try Self.decodeOne(&rng) }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("GhosttyAction.oneInput", seed: 0x05C7, iterations: 1_024)
        // Choice tapes: the tag (OSC 7 pwd, OSC 8 open, OSC 9;4 progress), union bytes, then the text.
        let tapes: [[UInt8]] = [[UInt8(GHOSTTY_ACTION_PWD.rawValue)], [UInt8(GHOSTTY_ACTION_OPEN_URL.rawValue)],
                                [UInt8(GHOSTTY_ACTION_PROGRESS_REPORT.rawValue), 1, 0xFF]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }
}
