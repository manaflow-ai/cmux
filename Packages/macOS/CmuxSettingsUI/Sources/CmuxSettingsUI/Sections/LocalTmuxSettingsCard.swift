import CmuxFoundation
import SwiftUI

@MainActor
struct LocalTmuxSettingsCard: View {
    let hostActions: SettingsHostActions

    @State private var sessions: [LocalTmuxSessionSummary] = []
    @State private var sessionName = ""
    @State private var isLoading = false
    @State private var actionInFlight = false
    @State private var errorMessage: String?
    @State private var tasks = MainActorTaskStore<String>()

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:terminal:session-persistence",
                String(
                    localized: "settings.terminal.localTmux.title",
                    defaultValue: "Keep Local Sessions Alive"
                ),
                subtitle: String(
                    localized: "settings.terminal.localTmux.subtitle",
                    defaultValue: "Named local-tmux sessions keep processes and scrollback alive across cmux quit, crashes, and updates. Ordinary terminals keep their current behavior."
                ),
                controlWidth: 300
            ) {
                HStack(spacing: 8) {
                    Text(statusText)
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Button(String(localized: "settings.terminal.localTmux.refresh", defaultValue: "Refresh")) {
                        refresh()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isLoading || actionInFlight)
                    .accessibilityIdentifier("SettingsTerminalLocalTmuxRefreshButton")

                    Link(
                        String(localized: "settings.terminal.localTmux.details", defaultValue: "Details"),
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
                    defaultValue: "Start Persistent Session"
                ),
                subtitle: String(
                    localized: "settings.terminal.localTmux.start.subtitle",
                    defaultValue: "Creates a named local-tmux session in the selected workspace directory and attaches it to cmux."
                ),
                controlWidth: 300
            ) {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "settings.terminal.localTmux.name", defaultValue: "Session name"),
                        text: $sessionName
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .accessibilityIdentifier("SettingsTerminalLocalTmuxNameField")

                    Button(String(localized: "settings.terminal.localTmux.startButton", defaultValue: "Start")) {
                        startSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(actionInFlight || sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("SettingsTerminalLocalTmuxStartButton")
                }
            }

            if let errorMessage {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .action,
                    String(localized: "settings.terminal.localTmux.status", defaultValue: "Status"),
                    subtitle: errorMessage
                ) {
                    EmptyView()
                }
            }

            ForEach(sessions) { session in
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .action,
                    session.name,
                    subtitle: sessionSubtitle(session),
                    controlWidth: 130
                ) {
                    if session.isLive {
                        Button(
                            String(localized: "settings.terminal.localTmux.attachButton", defaultValue: "Attach")
                        ) {
                            attach(session)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(actionInFlight)
                        .accessibilityIdentifier("SettingsTerminalLocalTmuxAttachButton-\(session.id)")
                    } else {
                        Text(String(localized: "settings.terminal.localTmux.stale", defaultValue: "Stale"))
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("SettingsTerminalLocalTmuxCard")
        .task { await loadSessions() }
    }

    private var statusText: String {
        if isLoading {
            return String(localized: "settings.terminal.localTmux.checking", defaultValue: "Checking…")
        }
        let liveCount = sessions.filter(\.isLive).count
        if liveCount == 0 {
            return String(localized: "settings.terminal.localTmux.none", defaultValue: "No live sessions")
        }
        return String.localizedStringWithFormat(
            String(localized: "settings.terminal.localTmux.liveCount", defaultValue: "%lld live"),
            liveCount
        )
    }

    private func sessionSubtitle(_ session: LocalTmuxSessionSummary) -> String {
        var parts: [String] = []
        parts.append(
            session.isManaged
                ? String(localized: "settings.terminal.localTmux.managed", defaultValue: "Managed")
                : String(localized: "settings.terminal.localTmux.unmanaged", defaultValue: "Unmanaged")
        )
        if session.clientCount > 0 {
            parts.append(
                String.localizedStringWithFormat(
                    String(localized: "settings.terminal.localTmux.clients", defaultValue: "%lld client(s)"),
                    session.clientCount
                )
            )
        }
        if let cwd = session.cwd, !cwd.isEmpty {
            parts.append(cwd)
        }
        return parts.joined(separator: " · ")
    }

    private func loadSessions() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await hostActions.localTmuxSessions()
            errorMessage = nil
        } catch {
            sessions = []
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() {
        tasks.replaceOnMainActor("localTmuxRefresh") {
            await loadSessions()
        }
    }

    private func startSession() {
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        actionInFlight = true
        tasks.replaceOnMainActor("localTmuxAction") {
            defer { actionInFlight = false }
            do {
                try await hostActions.startLocalTmuxSession(name: name)
                sessionName = ""
                errorMessage = nil
                await loadSessions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func attach(_ session: LocalTmuxSessionSummary) {
        actionInFlight = true
        tasks.replaceOnMainActor("localTmuxAction") {
            defer { actionInFlight = false }
            do {
                try await hostActions.attachLocalTmuxSession(session)
                errorMessage = nil
                await loadSessions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
