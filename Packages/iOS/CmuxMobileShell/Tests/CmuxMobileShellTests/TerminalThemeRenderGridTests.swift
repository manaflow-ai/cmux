import CMUXMobileCore
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func renderGridThemesStayScopedToTheirSurfaceAndSelection() throws {
    let firstID = MobileTerminalPreview.ID(rawValue: "terminal-light")
    let secondID = MobileTerminalPreview.ID(rawValue: "terminal-dark")
    let store = MobileShellComposite.preview()
    store.selectedTerminalID = firstID
    var light = TerminalTheme.monokai
    light.background = "#f5f1e8"
    light.foreground = "#15202b"
    var dark = TerminalTheme.monokai
    dark.background = "#101820"
    dark.foreground = "#f4f7fa"

    let lightFrame = try MobileTerminalRenderGridFrame(
        surfaceID: firstID.rawValue,
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: light
    )
    let darkFrame = try MobileTerminalRenderGridFrame(
        surfaceID: secondID.rawValue,
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: dark
    )

    store.recordTerminalTheme(lightFrame)
    store.recordTerminalTheme(darkFrame)

    #expect(store.terminalTheme(for: firstID.rawValue) == light)
    #expect(store.terminalTheme(for: secondID.rawValue) == dark)
    #expect(store.activeTerminalTheme == light)

    store.selectedTerminalID = secondID
    #expect(store.activeTerminalTheme == dark)
}

@MainActor
@Test func hybridPrimaryAdvisoryFrameStillUpdatesTerminalTheme() throws {
    let surfaceID = "terminal-hybrid-theme"
    let store = MobileShellComposite.preview()
    store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
    store.terminalOutputTransport = .hybrid
    let outputStream = store.terminalOutputStream(surfaceID: surfaceID)
    var light = TerminalTheme.monokai
    light.background = "#f4f0df"
    light.foreground = "#17212b"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: light
    )

    store.deliverAuthoritativeTerminalRenderGrid(frame, source: "event")

    #expect(store.activeTerminalTheme == light)
    _ = outputStream
}

@MainActor
@Test func olderFullFrameCannotReplaceNewerThemeRevision() throws {
    let surfaceID = "terminal-ordered-theme"
    let store = MobileShellComposite.preview()
    var oldTheme = TerminalTheme.monokai
    oldTheme.background = "#111111"
    var newTheme = TerminalTheme.monokai
    newTheme.background = "#f4f0df"
    let newer = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 7,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: newTheme,
        terminalThemeRevision: 2
    )
    let delayedOlder = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 7,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: oldTheme,
        terminalThemeRevision: 1
    )

    store.recordTerminalTheme(newer)
    store.recordTerminalTheme(delayedOlder)

    #expect(store.terminalTheme(for: surfaceID) == newTheme)
}

@MainActor
@Test func reconnectKeepsThemeButClearsItsOrderingFence() throws {
    let surfaceID = "terminal-reconnect-theme"
    let store = MobileShellComposite.preview()
    var theme = TerminalTheme.monokai
    theme.background = "#063f46"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: theme,
        terminalThemeRevision: 10
    )
    store.recordTerminalTheme(frame)

    store.resetTerminalThemeRevisionsForReconnect()

    #expect(store.terminalTheme(for: surfaceID) == theme)
    #expect(store.terminalThemeState.revisionsBySurfaceID.isEmpty)
}

@MainActor
@Test func workspacePruningDropsClosedSurfaceThemes() throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal-closed-theme"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: .monokai,
        terminalThemeRevision: 1
    )
    store.recordTerminalTheme(frame)

    store.pruneTerminalThemes(to: [])

    #expect(store.terminalThemeState.themesBySurfaceID[surfaceID] == nil)
    #expect(store.terminalThemeState.revisionsBySurfaceID[surfaceID] == nil)
}
