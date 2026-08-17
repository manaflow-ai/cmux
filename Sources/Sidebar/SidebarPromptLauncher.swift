import AppKit
import SwiftUI

private struct PromptLauncherArrowCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> ArrowCursorView { ArrowCursorView() }
    func updateNSView(_ nsView: ArrowCursorView, context: Context) {}

    class ArrowCursorView: NSView {
        override func resetCursorRects() {
            discardCursorRects()
            addCursorRect(bounds, cursor: .arrow)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct SpinningCircleButton: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 2)
                .frame(width: 24, height: 24)
            Circle()
                .trim(from: 0, to: 0.65)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

struct SidebarPromptLauncher: View {
    @State private var model = PromptLauncherModel()
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore

    var body: some View {
        @Bindable var model = model
        return Group {
            if let config = cmuxConfigStore.promptLauncher {
                let repositoryID = config.repositories.contains(where: { $0.id == model.selectedRepository })
                    ? model.selectedRepository
                    : config.selectedDefaultRepositoryID
                let availableTargets = config.targets(forRepositoryID: repositoryID)
                let targetID = availableTargets.contains(where: { $0.id == model.selectedTarget })
                    ? model.selectedTarget
                    : config.selectedDefaultTargetID(forRepositoryID: repositoryID)
                let providerID = config.providers.contains(where: { $0.id == model.selectedProvider })
                    ? model.selectedProvider
                    : config.selectedDefaultProviderID
                VStack(alignment: .leading, spacing: 4) {
                    PromptTextEditorContainer(
                        text: $model.promptText,
                        placeholder: String(localized: "sidebar.prompt_launcher.placeholder",
                                            defaultValue: "Prompt\u{2026}"),
                        isEditable: !model.isLoading,
                        onSubmit: {
                            model.launch(
                                config: config,
                                tabManager: tabManager,
                                configSourcePath: cmuxConfigStore.promptLauncherSourcePath,
                                globalConfigPath: cmuxConfigStore.globalConfigPath
                            )
                        }
                    )
                    .frame(height: 120)

                    HStack(spacing: 6) {
                        Picker(
                            selection: Binding(
                                get: { targetID },
                                set: { model.selectedTarget = $0 }
                            ),
                            label: EmptyView()
                        ) {
                            ForEach(availableTargets, id: \.id) { target in
                                Text(target.title).font(.system(size: 10)).tag(target.id)
                            }
                        }
                        .controlSize(.small)
                        .frame(maxWidth: config.repositories.isEmpty ? 110 : .infinity)

                        Picker(
                            selection: Binding(
                                get: { providerID },
                                set: { model.selectedProvider = $0 }
                            ),
                            label: EmptyView()
                        ) {
                            ForEach(config.providers, id: \.id) { provider in
                                Text(provider.title).font(.system(size: 10)).tag(provider.id)
                            }
                        }
                        .controlSize(.small)
                        .frame(maxWidth: config.repositories.isEmpty ? 100 : .infinity)

                        if !config.repositories.isEmpty {
                            Picker(
                                selection: Binding(
                                    get: { repositoryID },
                                    set: { model.selectRepository($0, config: config) }
                                ),
                                label: EmptyView()
                            ) {
                                ForEach(config.repositories, id: \.id) { repository in
                                    Text(repository.title).font(.system(size: 10)).tag(repository.id)
                                }
                            }
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(
                                String(localized: "sidebar.prompt_launcher.repository", defaultValue: "Repository")
                            )
                        }

                        Spacer()

                        if model.isLoading {
                            SpinningCircleButton()
                        } else {
                            Button {
                                model.launch(
                                    config: config,
                                    tabManager: tabManager,
                                    configSourcePath: cmuxConfigStore.promptLauncherSourcePath,
                                    globalConfigPath: cmuxConfigStore.globalConfigPath
                                )
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 24, height: 24)
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.return, modifiers: [.command])
                            .accessibilityLabel(String(localized: "sidebar.prompt_launcher.send",
                                                       defaultValue: "Send"))
                        }
                    }
                    .overlay(PromptLauncherArrowCursorArea())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Divider() }
                .onAppear { model.configure(config) }
                .onChange(of: config) { _, newConfig in
                    model.configure(newConfig)
                }
            }
        }
    }
}
