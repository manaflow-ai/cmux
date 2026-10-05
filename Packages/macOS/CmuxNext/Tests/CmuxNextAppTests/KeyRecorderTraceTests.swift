import AppKit
@testable import CmuxNextApp
import Testing

/// nxdog49: debug.key reported action "closeTab" for a stroke the Keyboard
/// Shortcuts recorder took (a stale value). The trace says the recorder took
/// the key, and no action is reported for it.
@MainActor
struct KeyRecorderTraceTests {
    @Test func aRecorderStrokeIsTracedAsTheRecorders() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let router = try #require(services.keyRouter)
        var lines: [String] = []
        router.trace = { lines.append($0) }
        router.keyRecorder = { _, _ in true }
        #expect(router.interceptKeyDown(try KeyInterceptionTests.key("w", keyCode: 13, [.command]), in: nil))
        #expect(lines.contains("recorder: the Keyboard Shortcuts recorder took the key"))
        #expect(router.lastInterception == nil)
    }
}
