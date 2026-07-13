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
