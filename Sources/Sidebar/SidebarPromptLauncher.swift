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
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore

    var body: some View {
        @Bindable var model = tabManager.promptLauncherModel
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
                        isEditable: true,
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
                        .disabled(model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(String(localized: "sidebar.prompt_launcher.send",
                                                   defaultValue: "Send"))
                    }
                    .overlay(PromptLauncherArrowCursorArea())

                    ForEach(model.visibleJobs) { job in
                        PromptLauncherPendingCard(
                            job: job,
                            onRetry: {
                                model.retry(
                                    job,
                                    config: config,
                                    tabManager: tabManager,
                                    configSourcePath: cmuxConfigStore.promptLauncherSourcePath,
                                    globalConfigPath: cmuxConfigStore.globalConfigPath
                                )
                            },
                            onDismiss: { model.dismiss(job) }
                        )
                    }

                    ForEach(model.closeJobs) { job in
                        PromptLauncherClosingCard(
                            job: job,
                            onRetry: { model.retry(job) },
                            onDismiss: { model.dismiss(job) }
                        )
                    }
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

private struct PromptLauncherPendingCard: View {
    let job: PromptLauncherModel.Job
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        PromptLauncherOperationCard(
            title: job.prompt,
            detail: job.latestLine,
            isFailed: job.state == .failed,
            icon: "sparkles",
            onRetry: onRetry,
            onDismiss: onDismiss
        )
    }
}

private struct PromptLauncherClosingCard: View {
    let job: PromptLauncherModel.CloseJob
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        PromptLauncherOperationCard(
            title: job.workspaceName,
            detail: job.latestLine,
            isFailed: job.state == .failed,
            icon: "xmark.circle",
            onRetry: onRetry,
            onDismiss: onDismiss
        )
    }
}

private struct PromptLauncherOperationCard: View {
    let title: String
    let detail: String
    let isFailed: Bool
    let icon: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: isFailed ? "exclamationmark.triangle.fill" : icon)
                    .foregroundStyle(isFailed ? Color.red : Color.accentColor)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if !isFailed {
                    SpinningCircleButton()
                        .scaleEffect(0.58)
                        .frame(width: 16, height: 16)
                }
            }

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(isFailed ? Color.red : Color.secondary)
                .lineLimit(2)

            if isFailed {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button(String(localized: "sidebar.prompt_launcher.retry", defaultValue: "Retry"), action: onRetry)
                    Button(String(localized: "sidebar.prompt_launcher.dismiss", defaultValue: "Dismiss"), action: onDismiss)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFailed ? Color.red.opacity(0.08) : Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFailed ? Color.red.opacity(0.32) : Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
