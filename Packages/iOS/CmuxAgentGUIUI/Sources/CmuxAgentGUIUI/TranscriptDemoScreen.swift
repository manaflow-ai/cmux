#if DEBUG && os(iOS)
import CMUXMobileCore
import CmuxAgentGUIProjection
import CmuxMobileSupport
public import SwiftUI

/// DEBUG-only replay-driven transcript demo screen.
public struct TranscriptDemoScreen: View {
    @State private var model = TranscriptDemoModel()
    @State private var jumpToken = 0
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var demoText = ""
    @FocusState private var demoFieldFocused: Bool

    /// Creates the transcript demo screen.
    public init() {}

    public var body: some View {
        let theme = AgentGUITheme(terminalTheme: TerminalThemeStore.current)
        ZStack(alignment: .bottom) {
            TranscriptDemoControllerRepresentable(
                input: model.input,
                theme: theme,
                jumpToken: jumpToken,
                bottomChromeHeight: bottomChromeHeight
            )
            .ignoresSafeArea(.keyboard, edges: .bottom)

            composerSurface
        }
        .background(Color(theme.background).ignoresSafeArea())
        .navigationTitle(AgentGUIL10n.string("agent.demo.title", defaultValue: "Transcript Demo"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            model.tearDown()
        }
    }

    @ViewBuilder
    private var composerSurface: some View {
        if #available(iOS 26.0, *) {
            // Keep each control's glass local. A GlassEffectContainer here spans
            // the overlay and reprojects the moving transcript backdrop while the
            // keyboard presents, producing a stale horizontal materialization wipe.
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
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: DemoChromeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(DemoChromeHeightPreferenceKey.self) { height in
            bottomChromeHeight = height
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

            Button {
                jumpToken += 1
            } label: {
                controlIcon("arrow.down.to.line")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentGUIL10n.string("agent.demo.jump", defaultValue: "Jump to bottom"))
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
