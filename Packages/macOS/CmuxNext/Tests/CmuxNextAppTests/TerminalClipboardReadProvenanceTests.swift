import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

@Suite("Terminal clipboard read provenance")
struct TerminalClipboardReadProvenanceTests {
    @Test func anUnprovenLocalPTYStillRequiresConsent() {
        let host = TerminalClipboardReadService.requestHost
        #expect(host.kind == .unknown)
        #expect(ClipboardReadSetting.allow.decision(host: host.kind) == .ask)
    }
}
