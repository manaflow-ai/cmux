import CmuxFoundation
import Foundation
import SwiftUI

@MainActor
struct LocalTmuxSettingsCard: View {
    let hostActions: SettingsHostActions

    @State private var sessions: [LocalTmuxSessionSummary] = []
    @State private var liveSessionCount = 0
    @State private var refreshGeneration = 0
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
        .task(id: refreshGeneration) {
            await loadSessions(generation: refreshGeneration)
        }
    }

    /// Renders the cached live-session count without scanning the session array from body.
    private var statusText: String {
        if isLoading {
            return String(localized: "settings.terminal.localTmux.checking", defaultValue: "Checking…")
        }
        if liveSessionCount == 0 {
            return String(localized: "settings.terminal.localTmux.none", defaultValue: "No live sessions")
        }
        return String.localizedStringWithFormat(
            String(localized: "settings.terminal.localTmux.liveCount", defaultValue: "%lld live"),
            liveSessionCount
        )
    }

    /// Formats one already-decoded session row for display.
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

    /// Loads one generation of the authoritative session snapshot.
    private func loadSessions(generation: Int) async {
        guard generation == refreshGeneration else { return }
        isLoading = true
        defer {
            if generation == refreshGeneration {
                isLoading = false
            }
        }
        do {
            let loadedSessions = try await hostActions.localTmuxSessions()
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            sessions = loadedSessions
            liveSessionCount = loadedSessions.lazy.filter(\.isLive).count
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            sessions = []
            liveSessionCount = 0
            errorMessage = error.localizedDescription
        }
    }

    /// Requests a new lifecycle-bound session snapshot.
    private func refresh() {
        refreshGeneration &+= 1
    }

    /// Starts a named persistent session through the host-owned CLI bridge.
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
                refreshGeneration &+= 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Attaches the selected persistent session through the host-owned CLI bridge.
    private func attach(_ session: LocalTmuxSessionSummary) {
        actionInFlight = true
        tasks.replaceOnMainActor("localTmuxAction") {
            defer { actionInFlight = false }
            do {
                try await hostActions.attachLocalTmuxSession(session)
                errorMessage = nil
                refreshGeneration &+= 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
