import CMUXMobileCore
import CmuxMobileShellModel
import Observation
import Synchronization
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
@Test func hybridPrimaryAdvisoryFrameRepaintsTerminalThemeWithoutReplacingContent() async throws {
    let surfaceID = "terminal-hybrid-theme"
    let store = MobileShellComposite.preview()
    store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
    store.terminalOutputTransport = .hybrid
    var outputIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    var light = TerminalTheme.monokai
    light.background = "#f4f0df"
    light.foreground = "#17212b"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalForeground: light.foreground,
        terminalBackground: light.background,
        terminalCursorColor: light.cursor,
        terminalTheme: light,
        terminalConfigTheme: light,
        terminalThemeRevision: 1
    )

    store.deliverAuthoritativeTerminalRenderGrid(frame, source: "event")
    let themeChunk = try #require(await outputIterator.next())
    let themeBytes = try #require(String(data: themeChunk.data, encoding: .utf8))

    #expect(store.activeTerminalTheme == light)
    #expect(themeChunk.terminalConfigTheme == light)
    #expect(themeBytes.contains("\u{1B}]11;rgb:f4/f0/df\u{1B}\\"))
    #expect(!themeBytes.contains("\u{1B}[2J"))
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
@Test func olderThemeRevisionCannotEnqueueEqualSequenceFullFrame() async throws {
    let surfaceID = "terminal-ordered-theme-delivery"
    let store = MobileShellComposite.preview()
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    var oldTheme = TerminalTheme.monokai
    oldTheme.background = "#111111"
    var newTheme = TerminalTheme.monokai
    newTheme.background = "#f4f0df"
    let newer = try delayedFrame(
        surfaceID: surfaceID,
        theme: newTheme,
        revision: 2,
        stateSeq: 7
    )
    let delayedOlder = try delayedFrame(
        surfaceID: surfaceID,
        theme: oldTheme,
        revision: 1,
        stateSeq: 7
    )
    var revisionless = delayedOlder
    revisionless.terminalThemeRevision = nil

    #expect(store.deliverTerminalRenderGrid(newer, surfaceID: surfaceID))
    let newerChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: newerChunk.streamToken)

    #expect(!store.deliverTerminalRenderGrid(delayedOlder, surfaceID: surfaceID))
    #expect(!store.deliverTerminalRenderGrid(revisionless, surfaceID: surfaceID))
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
        producerEpoch: "producer-one",
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
        producerEpoch: "producer-one",
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
        producerEpoch: "producer-before",
        connectionID: "connection-before"
    )
    store.recordTerminalTheme(try delayedFrame(
        surfaceID: surfaceID,
        theme: previousTheme,
        revision: 10
    ))

    store.prepareTerminalThemeRevisionAuthority(
        macInstanceTag: "mac-instance-after",
        producerEpoch: "producer-after",
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
@Test func restartedMacProcessAcceptsFreshThemeRevision() throws {
    let surfaceID = "terminal-restarted-mac-theme"
    let store = MobileShellComposite.preview()
    var previousTheme = TerminalTheme.monokai
    previousTheme.background = "#063f46"
    var restartedTheme = TerminalTheme.monokai
    restartedTheme.background = "#f4f0df"
    store.prepareTerminalThemeRevisionAuthority(
        macInstanceTag: "same-mac-tag",
        producerEpoch: "producer-before",
        connectionID: "connection-before"
    )
    store.recordTerminalTheme(try delayedFrame(
        surfaceID: surfaceID,
        theme: previousTheme,
        revision: 10
    ))

    store.prepareTerminalThemeRevisionAuthority(
        macInstanceTag: "same-mac-tag",
        producerEpoch: "producer-after",
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

@MainActor
@Test func reverseFrameKeepsRawConfigSeparateFromEffectiveChrome() throws {
    let surfaceID = "terminal-reverse-theme"
    let store = MobileShellComposite.preview()
    store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
    var rawConfig = TerminalTheme.monokai
    rawConfig.background = "#eeeeee"
    rawConfig.foreground = "#111111"
    var effective = rawConfig
    effective.background = rawConfig.foreground
    effective.foreground = rawConfig.background
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        modes: [.init(code: 5, ansi: false, on: true)],
        terminalForeground: rawConfig.foreground,
        terminalBackground: rawConfig.background,
        terminalTheme: effective,
        terminalConfigTheme: rawConfig,
        terminalThemeRevision: 1
    )

    store.recordTerminalTheme(frame)

    #expect(store.activeTerminalTheme == effective)
    #expect(store.activeTerminalConfigTheme == rawConfig)
}

@MainActor
@Test func renderGridReplayChunkCarriesMatchingRawConfigTheme() async throws {
    let surfaceID = "terminal-config-ordered-replay"
    let store = MobileShellComposite.preview()
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    var rawConfig = TerminalTheme.monokai
    rawConfig.cursorColorSemantic = .foreground
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: rawConfig,
        terminalConfigTheme: rawConfig,
        terminalThemeRevision: 1
    )

    #expect(store.deliverTerminalRenderGrid(frame, surfaceID: surfaceID))
    let chunk = try #require(await iterator.next())

    #expect(chunk.terminalConfigTheme == rawConfig)
    #expect(!chunk.data.isEmpty)
}

@MainActor
@available(macOS 15, *)
@Test func inactiveSurfaceThemeCacheDoesNotInvalidateSelectedThemeObservation() throws {
    let store = MobileShellComposite.preview()
    let selectedID = MobileTerminalPreview.ID(rawValue: "terminal-selected")
    store.selectedTerminalID = selectedID
    let invalidations = Mutex(0)
    withObservationTracking {
        _ = store.activeTerminalTheme
        _ = store.activeTerminalConfigTheme
        _ = store.terminalThemeGeneration
        _ = store.terminalConfigThemeGeneration
    } onChange: {
        invalidations.withLock { $0 += 1 }
    }
    var inactive = TerminalTheme.monokai
    inactive.background = "#f4f0df"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-inactive",
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: inactive,
        terminalConfigTheme: inactive,
        terminalThemeRevision: 1
    )

    store.recordTerminalTheme(frame)

    #expect(invalidations.withLock { $0 } == 0)
}

@MainActor
@Test func effectiveOnlyThemeChangeDoesNotScheduleRawConfigUpdate() throws {
    let surfaceID = "terminal-osc-theme"
    let store = MobileShellComposite.preview()
    store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
    let config = TerminalTheme.monokai
    store.applyTerminalTheme(config)
    let configGeneration = store.terminalConfigThemeGeneration
    var effective = config
    effective.palette[4] = "#123456"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: effective,
        terminalConfigTheme: config,
        terminalThemeRevision: 1
    )

    store.recordTerminalTheme(frame)

    #expect(store.activeTerminalTheme == effective)
    #expect(store.terminalConfigThemeGeneration == configGeneration)
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
