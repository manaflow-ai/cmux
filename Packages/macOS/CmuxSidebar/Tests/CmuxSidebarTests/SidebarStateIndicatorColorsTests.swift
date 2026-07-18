import Testing
@testable import CmuxSidebar

@Suite("SidebarStateIndicatorColors")
struct SidebarStateIndicatorColorsTests {
    @Test func emptyConfigurationHasNoOverrides() {
        let colors = SidebarStateIndicatorColors()
        #expect(colors.isEmpty)
        #expect(colors.colorHex(for: .running) == nil)
        #expect(colors.colorHex(for: .needsInput) == nil)
        #expect(colors.colorHex(for: .idle) == nil)
        #expect(colors.overrideColorsByKey(statesByKey: ["claude_code": .running]).isEmpty)
    }

    @Test func emptyAndWhitespaceHexesNormalizeToNil() {
        let colors = SidebarStateIndicatorColors(
            runningHex: "",
            needsInputHex: "   ",
            idleHex: "\n"
        )
        #expect(colors.isEmpty)
    }

    @Test func colorHexReturnsTheConfiguredStateColor() {
        let colors = SidebarStateIndicatorColors(
            runningHex: "#FF9500",
            needsInputHex: "#FF3B30",
            idleHex: "#8E8E93"
        )
        #expect(!colors.isEmpty)
        #expect(colors.colorHex(for: .running) == "#FF9500")
        #expect(colors.colorHex(for: .needsInput) == "#FF3B30")
        #expect(colors.colorHex(for: .idle) == "#8E8E93")
    }

    @Test func overrideColorsByKeyOnlyIncludesConfiguredStates() {
        let colors = SidebarStateIndicatorColors(runningHex: "#FF9500")
        let overrides = colors.overrideColorsByKey(statesByKey: [
            "claude_code": .running,
            "codex": .needsInput,
            "gemini": .idle,
        ])
        #expect(overrides == ["claude_code": "#FF9500"])
    }

    @Test func overrideColorsByKeyCoversEveryConfiguredState() {
        let colors = SidebarStateIndicatorColors(
            runningHex: "#FF9500",
            needsInputHex: "#FF3B30",
            idleHex: "#8E8E93"
        )
        let overrides = colors.overrideColorsByKey(statesByKey: [
            "claude_code": .running,
            "codex": .needsInput,
            "gemini": .idle,
        ])
        #expect(overrides == [
            "claude_code": "#FF9500",
            "codex": "#FF3B30",
            "gemini": "#8E8E93",
        ])
    }

    // needsInput must win over running: with one panel running and a sibling
    // panel blocked under the same status key, the pill has to surface the
    // blocked state — that's what the needs-input color exists for.
    @Test(arguments: [
        (SidebarStateIndicatorState.needsInput, SidebarStateIndicatorState.running, SidebarStateIndicatorState.needsInput),
        (.needsInput, .idle, .needsInput),
        (.running, .idle, .running),
        (.running, .running, .running),
        (.idle, .idle, .idle),
    ] as [(SidebarStateIndicatorState, SidebarStateIndicatorState, SidebarStateIndicatorState)])
    func dominatingPrefersNeedsInputThenRunningThenIdle(
        lhs: SidebarStateIndicatorState,
        rhs: SidebarStateIndicatorState,
        expected: SidebarStateIndicatorState
    ) {
        #expect(lhs.dominating(rhs) == expected)
        #expect(rhs.dominating(lhs) == expected)
    }
}
