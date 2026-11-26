import Testing

@testable import CmuxTerminal

@MainActor
@Suite("Terminal surface text capture")
struct TerminalSurfaceTextCaptureTests {
    @Test("bounded screen tail uses the native bounded formatter")
    func boundedScreenTailUsesNativeFormatter() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }

        #expect(
            fixture.surface.readBoundedScreenTailVT(
                maxRows: 4_000,
                maxBytes: 400_000
            ) == "bounded-tail\r\n"
        )
    }

    @Test("nonpositive bounded capture limits fail closed")
    func nonpositiveLimitsFailClosed() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }

        #expect(fixture.surface.readBoundedScreenTailVT(maxRows: 0, maxBytes: 1) == nil)
        #expect(fixture.surface.readBoundedScreenTailVT(maxRows: 1, maxBytes: 0) == nil)
    }
}
