#if os(iOS)
public import CMUXMobileCore
import CmuxAgentGUIProjection
public import CmuxAgentReplica
public import CmuxAgentSync
public import SwiftUI

/// Live transcript surface backed by ``AgentSyncEngine`` conversation replication.
public struct TranscriptLiveView: View {
    private let engine: AgentSyncEngine
    private let sessionID: AgentSessionID
    private let bottomChromeHeight: CGFloat
    private let terminalTheme: TerminalTheme
    private let terminalThemeGeneration: UInt64
    @State private var input = TranscriptProjectionInput(entries: [])
    @State private var driver: TranscriptProjectionDriver?
    private var driverKey: TranscriptLiveDriverKey {
        TranscriptLiveDriverKey(engine: engine, sessionID: sessionID)
    }

    /// Creates a live transcript surface.
    /// - Parameters:
    ///   - engine: Sync engine that owns the session directory and conversations.
    ///   - sessionID: Agent session to open and render.
    ///   - bottomChromeHeight: Height occupied by bottom composer chrome.
    ///   - terminalTheme: Current terminal theme reported by the attached Mac.
    ///   - terminalThemeGeneration: Observable generation for terminal-theme changes.
    public init(
        engine: AgentSyncEngine,
        sessionID: AgentSessionID,
        bottomChromeHeight: CGFloat,
        terminalTheme: TerminalTheme,
        terminalThemeGeneration: UInt64
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.bottomChromeHeight = bottomChromeHeight
        self.terminalTheme = terminalTheme
        self.terminalThemeGeneration = terminalThemeGeneration
    }

    public var body: some View {
        TranscriptLiveControllerRepresentable(
            input: input,
            bottomChromeHeight: bottomChromeHeight,
            theme: AgentGUITheme(terminalTheme: terminalTheme),
            terminalThemeGeneration: terminalThemeGeneration
        )
        .onAppear {
            startDriverIfNeeded()
        }
        .onDisappear {
            stopDriver()
        }
        .onChange(of: driverKey) { _, _ in
            restartDriver()
        }
    }

    private func startDriverIfNeeded() {
        guard driver == nil else { return }
        let nextDriver = TranscriptProjectionDriver(engine: engine, sessionID: sessionID) { nextInput in
            input = nextInput
        }
        driver = nextDriver
        nextDriver.start()
    }

    private func stopDriver() {
        driver?.stop()
        driver = nil
    }

    private func restartDriver() {
        stopDriver()
        input = TranscriptProjectionInput(entries: [])
        startDriverIfNeeded()
    }
}
#endif
