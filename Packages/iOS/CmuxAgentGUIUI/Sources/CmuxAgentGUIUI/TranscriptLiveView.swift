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
    private let density: TranscriptDensity
    private let onShowTerminal: () -> Void
    private let onShowActivity: (TranscriptActivityDetails) -> Void
    @State private var input = TranscriptProjectionInput(entries: [])
    @State private var driver: TranscriptProjectionDriver?
    @State private var answeringAskID: String?
    @State private var failedAskID: String?
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
    ///   - density: Current transcript spacing and metadata-type register.
    public init(
        engine: AgentSyncEngine,
        sessionID: AgentSessionID,
        bottomChromeHeight: CGFloat,
        terminalTheme: TerminalTheme,
        terminalThemeGeneration: UInt64,
        density: TranscriptDensity,
        onShowTerminal: @escaping () -> Void = {},
        onShowActivity: @escaping (TranscriptActivityDetails) -> Void = { _ in }
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.bottomChromeHeight = bottomChromeHeight
        self.terminalTheme = terminalTheme
        self.terminalThemeGeneration = terminalThemeGeneration
        self.density = density
        self.onShowTerminal = onShowTerminal
        self.onShowActivity = onShowActivity
    }

    public var body: some View {
        let theme = AgentGUITheme(terminalTheme: terminalTheme)
        let syncPresentation = TranscriptSyncPresentation(
            phase: engine.connectivity.phase,
            consecutiveFailures: engine.connectivity.consecutiveFailureCount,
            input: input
        )
        ZStack {
            TranscriptLiveControllerRepresentable(
                input: input,
                bottomChromeHeight: bottomChromeHeight,
                theme: theme,
                terminalThemeGeneration: terminalThemeGeneration,
                density: density,
                answeringAskID: answeringAskID,
                failedAskID: failedAskID,
                onAnswer: answer,
                onShowTerminal: onShowTerminal,
                onShowActivity: onShowActivity
            )
            TranscriptSyncStatusView(
                presentation: syncPresentation,
                theme: theme,
                retry: { engine.retryNow() },
                showTerminal: onShowTerminal
            )
        }
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

    private func answer(_ ask: PendingAsk, choice: Int) {
        guard answeringAskID == nil, ask.options.indices.contains(choice) else { return }
        answeringAskID = ask.id
        failedAskID = nil
        Task { @MainActor in
            defer { answeringAskID = nil }
            do {
                try await engine.answer(sessionID: sessionID, askID: ask.id, choice: choice)
            } catch {
                failedAskID = ask.id
            }
        }
    }
}
#endif
