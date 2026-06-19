import Testing

@testable import CmuxTerminalCore

@Suite
struct GhosttyDefaultBackgroundUpdateScopeTests {
    @Test
    func prioritizesSurfaceOverAppAndUnscoped() {
        #expect(GhosttyDefaultBackgroundUpdateScope.app.shouldApply(over: .unscoped))
        #expect(GhosttyDefaultBackgroundUpdateScope.surface.shouldApply(over: .app))
        #expect(GhosttyDefaultBackgroundUpdateScope.surface.shouldApply(over: .surface))
        #expect(!GhosttyDefaultBackgroundUpdateScope.app.shouldApply(over: .surface))
        #expect(!GhosttyDefaultBackgroundUpdateScope.unscoped.shouldApply(over: .surface))
    }

    @Test
    func equalScopeApplies() {
        #expect(GhosttyDefaultBackgroundUpdateScope.unscoped.shouldApply(over: .unscoped))
        #expect(GhosttyDefaultBackgroundUpdateScope.app.shouldApply(over: .app))
    }

    @Test
    func logLabelsMatchRawCases() {
        #expect(GhosttyDefaultBackgroundUpdateScope.unscoped.logLabel == "unscoped")
        #expect(GhosttyDefaultBackgroundUpdateScope.app.logLabel == "app")
        #expect(GhosttyDefaultBackgroundUpdateScope.surface.logLabel == "surface")
    }
}
