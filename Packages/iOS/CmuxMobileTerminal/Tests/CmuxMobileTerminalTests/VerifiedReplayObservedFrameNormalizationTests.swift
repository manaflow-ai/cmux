#if canImport(UIKit)
import CMUXMobileCore
import Testing

@testable import CmuxMobileTerminal

@Suite("Verified replay observed-frame normalization")
struct VerifiedReplayObservedNormalizationTests {
    @Test("configured cursor default is equivalent to an inherited producer cursor")
    func configuredDefaultMatchesInheritedCursor() throws {
        let observed = try frame(cursorColor: "#98989D")

        let normalized = observed.normalizingVerifiedReplayCursor(
            expectedCursorColor: nil,
            configuredCursorColor: "#98989d"
        )

        #expect(normalized.terminalCursorColor == nil)
    }

    @Test("a nondefault cursor override remains visible to verification")
    func nondefaultOverrideRemains() throws {
        let observed = try frame(cursorColor: "#112233")

        let normalized = observed.normalizingVerifiedReplayCursor(
            expectedCursorColor: nil,
            configuredCursorColor: "#98989D"
        )

        #expect(normalized.terminalCursorColor == "#112233")
    }

    @Test("an explicit producer override is not collapsed")
    func explicitProducerOverrideRemains() throws {
        let observed = try frame(cursorColor: "#98989D")

        let normalized = observed.normalizingVerifiedReplayCursor(
            expectedCursorColor: "#98989D",
            configuredCursorColor: "#98989D"
        )

        #expect(normalized.terminalCursorColor == "#98989D")
    }

    private func frame(cursorColor: String?) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "surface",
            stateSeq: 1,
            renderEpoch: "epoch",
            renderRevision: 1,
            columns: 80,
            rows: 24,
            rowSpans: [],
            terminalCursorColor: cursorColor
        )
    }
}
#endif
