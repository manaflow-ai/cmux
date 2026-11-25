import AppKit
import Carbon.HIToolbox
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// Script the callbacks an input method delivers at NSTextInputClient, then inspect the real
/// Ghostty encoder's outgoing bytes. This does not exercise the installed system input methods.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TerminalIMEInputTests {
    nonisolated struct Commit: Sendable {
        let preedit: [String]
        let text: String
    }

    nonisolated struct Trace: Sendable {
        let name: String
        let commits: [Commit]
        var text: String { commits.map(\.text).joined() }
    }

    nonisolated static let traces: [Trace] = [
        Trace(name: "Korean 2-set", commits: [
            Commit(preedit: ["ㅇ", "아", "안"], text: "안"),
            Commit(preedit: ["ㄴ", "녀", "녕"], text: "녕"),
            Commit(preedit: ["ㅎ", "하"], text: "하"),
            Commit(preedit: ["ㅅ", "세"], text: "세"),
            Commit(preedit: ["ㅇ", "요"], text: "요"),
        ]),
        Trace(name: "Japanese kana-kanji", commits: [
            Commit(preedit: ["に", "にほ", "にほんご", "日本語"], text: "日本語"),
        ]),
        Trace(name: "Simplified Chinese pinyin", commits: [
            Commit(preedit: ["n", "ni", "nihao", "你好"], text: "你好"),
        ]),
        Trace(name: "Vietnamese Telex", commits: [
            Commit(preedit: ["tie", "tiê", "tiên", "tiêng", "tiếng"], text: "tiếng"),
            Commit(preedit: [" "], text: " "),
            Commit(preedit: ["Vie", "Viê", "Viêt", "Việt"], text: "Việt"),
        ]),
    ]

    @Test(arguments: traces)
    func markedTextCommitsOnceThenOneReturnProducesOneCarriageReturn(_ trace: Trace) async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let (outgoing, continuation) = AsyncStream<TerminalOutgoing>.makeStream()
        defer { continuation.finish() }
        let view = TerminalSurfaceView(io: GHOSTTY_SURFACE_IO_MANUAL,
                                       input: TerminalInputSink(continuation: continuation), session: nil)
        try #require(view.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            window.contentView = nil
            window.close()
        }
        try #require(window.makeFirstResponder(view))

        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: UInt16(kVK_Return)))
        // KeyDownDispatchTests uses this guarded seam: postEvent/nextEvent terminated the
        // fleet's macOS 26 test process. insertText intentionally requires a current event.
        try #require(class_getInstanceVariable(NSApplication.self, "_currentEvent") != nil,
                     "NSApplication has no _currentEvent ivar on this macOS")
        let fence = "|ime-probe-end|"
        try driveInput(view, trace: trace, enter: enter, fence: fence)
        let bytes = try #require(await Self.bytesThroughFence(outgoing, fence: Data(fence.utf8)),
                                 "\(trace.name) did not produce its output fence within ten seconds")
        #expect(bytes == Data((trace.text + "\r" + fence).utf8),
                "\(trace.name) emitted preedit, lost or repeated committed text, or sent the wrong number of Returns")
    }

    /// Keep the current-event seam synchronous, restoring it before another main-actor test
    /// can run while this test awaits the Ghostty IO thread.
    private func driveInput(_ view: TerminalSurfaceView, trace: Trace, enter: NSEvent, fence: String) throws {
        let previousEvent = NSApp.currentEvent
        NSApp.setValue(enter, forKey: "currentEvent")
        defer { NSApp.setValue(previousEvent, forKey: "currentEvent") }
        try #require(NSApp.currentEvent === enter)

        for commit in trace.commits {
            for preedit in commit.preedit {
                view.setMarkedText(preedit, selectedRange: NSRange(location: (preedit as NSString).length, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
                #expect(view.hasMarkedText())
                #expect(view.markedText.string == preedit)
            }
            view.insertText(commit.text as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(!view.hasMarkedText(), "\(trace.name) left stale preedit after a commit")
        }
        view.keyDown(with: enter)
        view.keyUp(with: try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: enter.timestamp + 0.01,
            windowNumber: enter.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: UInt16(kVK_Return))))

        // A final text callback is an ordered fence in the same Ghostty input stream. It lets
        // us detect extra preedit, repeated syllables or Returns without a quiet-period sleep.
        view.insertText(fence as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private static func bytesThroughFence(_ stream: AsyncStream<TerminalOutgoing>, fence: Data) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var bytes = Data()
                for await event in stream {
                    if case .bytes(let chunk) = event { bytes.append(chunk) }
                    if bytes.suffix(fence.count) == fence { return bytes }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test func composingReturnIsFilteredUntilTheFollowingPlainReturn() {
        #expect(GhosttyInput.isComposingControl("\r", composing: true))
        #expect(!GhosttyInput.isComposingControl("\r", composing: false))
        #expect(GhosttyInput.isComposingControl("\u{1b}", composing: true))
        #expect(!GhosttyInput.isComposingControl("\u{1b}", composing: false))
    }

    @Test func candidateNavigationReplaysOnlyAfterCommit() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                charactersIgnoringModifiers: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                isARepeat: false,
                keyCode: UInt16(kVK_DownArrow)
            )
        )
        #expect(GhosttyInput.shouldReplayAfterCommit(event))
        let left = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
                charactersIgnoringModifiers: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
                isARepeat: false,
                keyCode: UInt16(kVK_LeftArrow)
            )
        )
        #expect(!GhosttyInput.shouldReplayAfterCommit(left))
    }
}
