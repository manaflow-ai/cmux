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
@Test func staleTerminalContentStillAdvancesRevisionedThemeMetadata() throws {
    let surfaceID = "terminal-stale-content-fresh-theme"
    let store = MobileShellComposite.preview()
    store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
    let outputStream = store.terminalOutputStream(surfaceID: surfaceID)
    store.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: 20, fullReplacement: false)
    var light = TerminalTheme.monokai
    light.background = "#f4f0df"
    light.foreground = "#17212b"
    let staleContent = try delayedFrame(
        surfaceID: surfaceID,
        theme: light,
        revision: 2,
        stateSeq: 10
    )

    store.deliverAuthoritativeTerminalRenderGrid(staleContent, source: "event")

    #expect(store.activeTerminalTheme == light)
    #expect(store.terminalThemeState.revisionsBySurfaceID[surfaceID] == 2)
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
@Test func reconnectToSameMacKeepsThemeOrderingFence() throws {
    let surfaceID = "terminal-reconnect-theme"
    let store = MobileShellComposite.preview()
    var theme = TerminalTheme.monokai
    theme.background = "#063f46"
    store.prepareTerminalThemeRevisionAuthority(
        macInstanceTag: "mac-theme-instance",
        connectionID: "connection-before"
    )
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

    store.prepareTerminalThemeRevisionAuthority(
        macInstanceTag: "mac-theme-instance",
        connectionID: "connection-after"
    )
    store.recordTerminalTheme(try delayedFrame(
        surfaceID: surfaceID,
        theme: .monokai,
        revision: 9
    ))

    #expect(store.terminalTheme(for: surfaceID) == theme)
    #expect(store.terminalThemeState.revisionsBySurfaceID[surfaceID] == 10)
}

@MainActor
@Test func newMacInstanceAcceptsItsFreshThemeRevision() throws {
    let surfaceID = "terminal-new-mac-theme"
    let store = MobileShellComposite.preview()
    var previousTheme = TerminalTheme.monokai
    previousTheme.background = "#063f46"
    var restartedTheme = TerminalTheme.monokai
    restartedTheme.background = "#f4f0df"
    store.prepareTerminalThemeRevisionAuthority(
        macInstanceTag: "mac-instance-before",
        connectionID: "connection-before"
    )
    store.recordTerminalTheme(try delayedFrame(
        surfaceID: surfaceID,
        theme: previousTheme,
        revision: 10
    ))

    store.prepareTerminalThemeRevisionAuthority(
        macInstanceTag: "mac-instance-after",
        connectionID: "connection-after"
    )
    store.recordTerminalTheme(try delayedFrame(
        surfaceID: surfaceID,
        theme: restartedTheme,
        revision: 1
    ))

    #expect(store.terminalTheme(for: surfaceID) == restartedTheme)
    #expect(store.terminalThemeState.revisionsBySurfaceID[surfaceID] == 1)
}

@MainActor
@Test func workspaceReplacementRepairsThemeSelectionBeforeVisibleSurfaceUpdates() throws {
    let removedID = MobileTerminalPreview.ID(rawValue: "terminal-removed")
    let visibleID = MobileTerminalPreview.ID(rawValue: "terminal-visible")
    let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-theme-selection")
    let initialWorkspace = MobileWorkspacePreview(
        id: workspaceID,
        name: "Theme selection",
        terminals: [
            MobileTerminalPreview(id: removedID, name: "Removed"),
            MobileTerminalPreview(id: visibleID, name: "Visible"),
        ]
    )
    let store = MobileShellComposite(workspaces: [initialWorkspace])
    var visibleTheme = TerminalTheme.monokai
    visibleTheme.background = "#f4f0df"
    visibleTheme.foreground = "#17212b"

    store.replaceForegroundWorkspaceState([
        MobileWorkspacePreview(
            id: workspaceID,
            name: "Theme selection",
            terminals: [MobileTerminalPreview(id: visibleID, name: "Visible")]
        ),
    ])
    store.recordTerminalTheme(try delayedFrame(
        surfaceID: visibleID.rawValue,
        theme: visibleTheme,
        revision: 1
    ))

    #expect(store.selectedTerminalID == visibleID)
    #expect(store.activeTerminalTheme == visibleTheme)
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

private func delayedFrame(
    surfaceID: String,
    theme: TerminalTheme,
    revision: UInt64,
    stateSeq: UInt64 = 1
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: stateSeq,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: theme,
        terminalThemeRevision: revision
    )
}
