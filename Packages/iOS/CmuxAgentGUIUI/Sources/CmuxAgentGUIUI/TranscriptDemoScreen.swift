#if DEBUG && os(iOS)
import CMUXMobileCore
import CmuxAgentGUIProjection
import CmuxMobileSupport
public import SwiftUI

/// DEBUG-only replay-driven transcript demo screen.
public struct TranscriptDemoScreen: View {
    @State private var model = TranscriptDemoModel()
    @State private var density: TranscriptDensity

    /// Creates the transcript demo screen.
    public init() {
        let rawDensity = UITestEnvironmentConfig(
            environment: ProcessInfo.processInfo.environment
        ).transcriptDensity
        _density = State(initialValue: rawDensity.flatMap(TranscriptDensity.init(rawValue:)) ?? .comfortable)
    }

    public var body: some View {
        let theme = AgentGUITheme(terminalTheme: .monokai)
        TranscriptDemoControllerRepresentable(
            input: model.input,
            theme: theme,
            jumpToken: 0,
            bottomChromeHeight: 0,
            density: density,
            composerModel: model,
            densityBinding: $density
        )
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color(theme.background).ignoresSafeArea())
        .navigationTitle(AgentGUIL10n.string("agent.demo.title", defaultValue: "Transcript Demo"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            model.tearDown()
        }
    }
}
#endif
