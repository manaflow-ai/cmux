import Foundation
import SwiftUI

@MainActor
struct LocalTmuxSettingsCard: View {
    @State private var model: LocalTmuxSettingsModel

    init(hostActions: SettingsHostActions) {
        _model = State(initialValue: LocalTmuxSettingsModel(hostActions: hostActions))
    }

    var body: some View {
        @Bindable var model = model

        return SettingsCard {
            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:terminal:session-persistence",
                String(
                    localized: "settings.terminal.localTmux.title",
                    defaultValue: "Keep Local Sessions Alive",
                    bundle: .module
                ),
                subtitle: String(
                    localized: "settings.terminal.localTmux.subtitle",
                    defaultValue: "Named local-tmux sessions keep processes and scrollback alive across cmux quit, crashes, and updates. Ordinary terminals keep their current behavior.",
                    bundle: .module
                ),
                controlWidth: 300
            ) {
                HStack(spacing: 8) {
                    Text(statusText)
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Button(String(localized: "settings.terminal.localTmux.refresh", defaultValue: "Refresh", bundle: .module)) {
                        model.refresh()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.phase != .idle)
                    .accessibilityIdentifier("SettingsTerminalLocalTmuxRefreshButton")

                    Link(
                        String(localized: "settings.terminal.localTmux.details", defaultValue: "Details", bundle: .module),
                        destination: URL(string: "https://github.com/manaflow-ai/cmux/blob/main/docs/local-tmux.md")!
                    )
                    .cmuxFont(.caption)
                    .accessibilityIdentifier("SettingsTerminalLocalTmuxDocsLink")
                }
            }

            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .action,
                String(
                    localized: "settings.terminal.localTmux.start",
                    defaultValue: "Start Persistent Session",
                    bundle: .module
                ),
                subtitle: String(
                    localized: "settings.terminal.localTmux.start.subtitle",
                    defaultValue: "Creates a named local-tmux session in the selected workspace directory and attaches it to cmux.",
                    bundle: .module
                ),
                controlWidth: 300
            ) {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "settings.terminal.localTmux.name", defaultValue: "Session name", bundle: .module),
                        text: $model.sessionName
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .accessibilityIdentifier("SettingsTerminalLocalTmuxNameField")

                    Button(String(localized: "settings.terminal.localTmux.startButton", defaultValue: "Start", bundle: .module)) {
                        model.startSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        model.phase != .idle
                            || model.sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("SettingsTerminalLocalTmuxStartButton")
                }
            }

            if let errorMessage = model.errorMessage {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .action,
                    String(localized: "settings.terminal.localTmux.status", defaultValue: "Status", bundle: .module),
                    subtitle: errorMessage
                ) {
                    EmptyView()
                }
            }

            ForEach(model.sessions) { session in
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .action,
                    session.name,
                    subtitle: sessionSubtitle(session),
                    controlWidth: 130
                ) {
                    if session.isLive {
                        Button(
                            String(localized: "settings.terminal.localTmux.attachButton", defaultValue: "Attach", bundle: .module)
                        ) {
                            model.attach(session)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.phase != .idle)
                        .accessibilityIdentifier("SettingsTerminalLocalTmuxAttachButton-\(session.id)")
                    } else {
                        Text(String(localized: "settings.terminal.localTmux.stale", defaultValue: "Stale", bundle: .module))
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("SettingsTerminalLocalTmuxCard")
        .task {
            model.refresh()
        }
        .onDisappear {
            model.cancel()
        }
    }

    /// Renders the model's cached live-session count without scanning rows from body.
    private var statusText: String {
        if model.isLoading {
            return String(localized: "settings.terminal.localTmux.checking", defaultValue: "Checking…", bundle: .module)
        }
        if model.liveSessionCount == 0 {
            return String(localized: "settings.terminal.localTmux.none", defaultValue: "No live sessions", bundle: .module)
        }
        let liveLabel = String(
            localized: "settings.terminal.localTmux.liveCount",
            defaultValue: "Live",
            bundle: .module
        )
        return "\(liveLabel): \(model.liveSessionCount)"
    }

    /// Formats one already-decoded session row for display.
    private func sessionSubtitle(_ session: LocalTmuxSessionSummary) -> String {
        var parts: [String] = []
        parts.append(
            session.isManaged
                ? String(localized: "settings.terminal.localTmux.managed", defaultValue: "Managed", bundle: .module)
                : String(localized: "settings.terminal.localTmux.unmanaged", defaultValue: "Unmanaged", bundle: .module)
        )
        if session.clientCount > 0 {
            let clientsLabel = String(
                localized: "settings.terminal.localTmux.clients",
                defaultValue: "Clients",
                bundle: .module
            )
            parts.append("\(clientsLabel): \(session.clientCount)")
        }
        if let cwd = session.cwd, !cwd.isEmpty {
            parts.append(cwd)
        }
        return parts.joined(separator: " · ")
    }
}
