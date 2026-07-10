#if DEBUG && os(iOS)
public import SwiftUI

/// DEBUG-only replay-driven transcript demo screen.
public struct TranscriptDemoScreen: View {
    @State private var model = TranscriptDemoModel()
    @State private var jumpToken = 0

    /// Creates the transcript demo screen.
    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            TranscriptDemoControllerRepresentable(
                input: model.input,
                focusToken: model.focusToken,
                jumpToken: jumpToken
            )
            .ignoresSafeArea(.keyboard, edges: .bottom)
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .navigationTitle(AgentGUIL10n.string("agent.demo.title", defaultValue: "Transcript Demo"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            model.tearDown()
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker(AgentGUIL10n.string("agent.demo.speed", defaultValue: "Speed"), selection: $model.speed) {
                Text(AgentGUIL10n.rowsPerSecond(2)).tag(2)
                Text(AgentGUIL10n.rowsPerSecond(10)).tag(10)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(model.isPlaying
                ? AgentGUIL10n.string("agent.demo.pause", defaultValue: "Pause replay")
                : AgentGUIL10n.string("agent.demo.play", defaultValue: "Play replay"))

            Button {
                model.injectStreamingTick()
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
            .accessibilityLabel(AgentGUIL10n.string("agent.demo.streaming", defaultValue: "Inject streaming tick"))

            Button {
                model.toggleKeyboard()
            } label: {
                Image(systemName: "keyboard")
            }
            .accessibilityLabel(AgentGUIL10n.string("agent.demo.keyboard", defaultValue: "Toggle keyboard"))

            Button {
                jumpToken += 1
            } label: {
                Image(systemName: "arrow.down.to.line")
            }
            .accessibilityLabel(AgentGUIL10n.string("agent.demo.jump", defaultValue: "Jump to bottom"))
        }
    }
}
#endif
