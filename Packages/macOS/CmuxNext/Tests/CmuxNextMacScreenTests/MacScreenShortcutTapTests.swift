import AppKit
import CmuxNextRemoteView
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// Send System Shortcuts runs its event tap in the Screen Sharing helper
/// (`cmux-screen-sharing __shortcut-tap`, cmux-rd-host src/shortcut_tap.rs), so cmux needs no
/// Accessibility of its own. The app's side: the helper's lines read as keys, the app's control
/// line is what the helper parses, and a spawned process's keys reach the app in order.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct MacScreenShortcutTapTests {
    @Test func readsTheHelpersLinesAcrossChunks() {
        var lines = MacScreenShortcutTapLines()
        #expect(lines.push(Data("{\"ready\":true}\n{\"key_code\":48,\"modi".utf8)) == [MacScreenShortcutTapLine(ready: true)])
        let rest = lines.push(Data("fiers\":1048576,\"down\":true,\"repeat\":false}\n\n{\"newer\":1}\n".utf8))
        #expect(rest.count == 2)
        #expect(rest.first?.key == RemoteTapKey(keyCode: 48, modifiers: .command, down: true))
        // A newer helper's line is no key and no error.
        #expect(rest.last == MacScreenShortcutTapLine())
        #expect(rest.last?.key == nil)
    }

    @Test func aKeysModifiersAreNSEventFlags() {
        var lines = MacScreenShortcutTapLines()
        let flags = NSEvent.ModifierFlags([.command, .shift]).rawValue
        let read = lines.push(Data("{\"key_code\":23,\"modifiers\":\(flags),\"down\":false,\"repeat\":true}\n".utf8))
        #expect(read.first?.key == RemoteTapKey(keyCode: 23, modifiers: [.command, .shift], down: false, isRepeat: true))
    }

    @Test func theControlLineIsTheOneTheHelperParses() throws {
        let hold = MacScreenShortcutTapControl.hold(release: .default)
        let json = try #require(String(data: hold.line, encoding: .utf8))
        #expect(json.hasSuffix("\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: hold.line) as? [String: Any])
        #expect(object["hold"] as? Bool == true)
        let release = try #require(object["release"] as? [String: Any])
        // Control-Option-Escape: kVK_Escape and NSEvent's Control | Option bits (cmux-rd-host Chord::DEFAULT_RELEASE).
        #expect(release["key_code"] as? Int == 53)
        #expect(release["modifiers"] as? Int == (1 << 18) | (1 << 19))
        let letGo = try #require(try JSONSerialization.jsonObject(with: MacScreenShortcutTapControl.letGo.line) as? [String: Any])
        #expect(letGo["hold"] as? Bool == false)
    }

    /// A shell stands in for the helper: it reads the app's control line, echoes it on stderr,
    /// and prints ready and two keys.
    static let script = """
    read control
    printf '%s\\n' '{"ready":true}' '{"key_code":48,"modifiers":1048576,"down":true,"repeat":false}' \
      '{"key_code":48,"modifiers":0,"down":false,"repeat":false}'
    cat >/dev/null
    """

    @Test func aSpawnedTapsKeysArriveInOrderAndStopEndsIt() async throws {
        let tap = MacScreenShortcutTap()
        var keys: [RemoteTapKey] = []
        let arrived = AsyncStream.makeStream(of: Void.self)
        tap.onKey = { key in
            keys.append(key)
            if keys.count == 2 { arrived.continuation.yield() }
        }
        var ended = false
        tap.onEnd = { _ in ended = true }
        tap.send(.hold(release: .default))
        try tap.start { stdin, stdout, stderr in
            try MacScreenHelper.spawn(URL(fileURLWithPath: "/bin/sh"), ["-c", Self.script], stdin: stdin, stdout: stdout, stderr: stderr)
        }
        #expect(tap.isRunning)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in arrived.stream { return } }
            group.addTask { try? await Task.sleep(for: .seconds(10)) }
            await group.next()
            group.cancelAll()
        }
        #expect(keys == [RemoteTapKey(keyCode: 48, modifiers: .command, down: true),
                         RemoteTapKey(keyCode: 48, modifiers: [], down: false)])
        tap.stop()
        #expect(!tap.isRunning)
        // A stopped tap never reports an end of its own.
        #expect(!ended)
    }

    @Test func aRefusedTapReportsWhy() async throws {
        let tap = MacScreenShortcutTap()
        let (reasons, continuation) = AsyncStream.makeStream(of: String?.self)
        tap.onEnd = { continuation.yield($0) }
        try tap.start { stdin, stdout, stderr in
            try MacScreenHelper.spawn(URL(fileURLWithPath: "/bin/sh"),
                                      ["-c", "printf '%s\\n' '{\"error\":\"no Accessibility\"}'"],
                                      stdin: stdin, stdout: stdout, stderr: stderr)
        }
        var reason: String??
        for await next in reasons {
            reason = next
            break
        }
        #expect(reason == .some("no Accessibility"))
        #expect(!tap.isRunning)
    }
}
