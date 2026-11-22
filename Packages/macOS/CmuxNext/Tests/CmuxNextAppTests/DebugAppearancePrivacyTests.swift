import AppKit
import CmuxNextSettings
import Testing
@testable import CmuxNextApp

/// `debug.appearance` with a `mode` is a capture tour's light/dark switch: its answer goes into the capture's report,
/// and the capture's privacy check refuses a path under the capture account's home (each bundle path is one). Only
/// the read (no `mode`, as `window_look.py` asks) names the bundle's theme folder.
@MainActor
@Suite struct DebugAppearancePrivacyTests {
    init() { _ = NSApplication.shared }

    @Test func aSwitchAnswersNoPath() throws {
        guard case .object(let answer) = DebugAppearance.handle(["mode": .string("system")]) else {
            Issue.record("debug.appearance answered no object")
            return
        }
        #expect(answer["themes"] == nil)
        #expect(answer["effective"] != nil)
        #expect(!answer.values.contains { if case .string(let text) = $0 { text.hasPrefix("/") } else { false } })
    }

    @Test func aReadNamesTheThemeFolder() throws {
        guard case .object(let answer) = DebugAppearance.handle([:]) else {
            Issue.record("debug.appearance answered no object")
            return
        }
        #expect(answer.keys.contains("themes"))
    }
}
