#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import CmuxMobileSupport
import Observation
import SwiftUI

struct TranscriptDemoComposerView: View {
    @Bindable var model: TranscriptDemoModel
    @Binding var density: TranscriptDensity
    let jumpToBottom: () -> Void

    @State private var demoText = ""
    @FocusState private var demoFieldFocused: Bool

    var body: some View {
        composerSurface
    }

    @ViewBuilder
    private var composerSurface: some View {
        if #available(iOS 26.0, *) {
            composerChrome
        } else {
            composerChrome
                .background(.bar)
        }
    }

    private var composerChrome: some View {
        VStack(spacing: 8) {
            MobileComposerFieldContainer(minHeight: 44) {
                TextField(
                    AgentGUIL10n.string("agent.demo.fieldPlaceholder", defaultValue: "Demo keyboard field"),
                    text: $demoText
                )
                .focused($demoFieldFocused)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
                .onSubmit {
                    demoFieldFocused = false
                }
            } trailing: {
                EmptyView()
            }

            controls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                controlIcon(model.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .disabled(!model.isPlaybackAvailable)
            .accessibilityLabel(model.isPlaying
                ? AgentGUIL10n.string("agent.demo.pause", defaultValue: "Pause replay")
                : AgentGUIL10n.string("agent.demo.play", defaultValue: "Play replay"))

            Button {
                model.injectStreamingTick()
            } label: {
                controlIcon("dot.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentGUIL10n.string("agent.demo.streaming", defaultValue: "Inject streaming tick"))

            Button {
                model.appendBurstRows()
            } label: {
                controlIcon("plus.message")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentGUIL10n.string("agent.demo.burstAppend", defaultValue: "Burst append five rows"))

            Toggle(isOn: Binding(
                get: { model.tallFixtureEnabled },
                set: { model.setTallFixtureEnabled($0) }
            )) {
                controlIcon("text.append")
            }
            .toggleStyle(.button)
            .accessibilityLabel(AgentGUIL10n.string("agent.demo.tallFixture", defaultValue: "Tall fixture"))

            Button {
                demoFieldFocused.toggle()
            } label: {
                controlIcon("keyboard")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentGUIL10n.string("agent.demo.keyboard", defaultValue: "Toggle keyboard"))

            Button(action: jumpToBottom) {
                controlIcon("arrow.down.to.line")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentGUIL10n.string("agent.demo.jump", defaultValue: "Jump to bottom"))

            Button {
                density = density == .comfortable ? .compact : .comfortable
            } label: {
                controlIcon(density == .comfortable
                    ? "rectangle.compress.vertical"
                    : "rectangle.expand.vertical")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentGUIL10n.string(
                "agent.demo.densityToggle",
                defaultValue: "Toggle transcript density"
            ))
            .accessibilityValue(density == .comfortable
                ? AgentGUIL10n.string("agent.demo.density.comfortable", defaultValue: "Comfortable")
                : AgentGUIL10n.string("agent.demo.density.compact", defaultValue: "Compact"))
            .accessibilityIdentifier("TranscriptDemoDensityToggle")
        }
        .padding(6)
        .mobileGlassField(cornerRadius: 24)
    }

    private func controlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 44, height: 44)
            .mobileGlassCircle()
    }
}
#endif
