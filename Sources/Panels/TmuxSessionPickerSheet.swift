import SwiftUI

/// Sheet shown after connecting to a remote that has tmux available.
/// Lets the user pick an existing session or create a new one.
struct TmuxSessionPickerSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    @State private var newSessionName: String = ""
    /// Prevents double-submission if the user taps Create rapidly.
    @State private var isSubmitting: Bool = false

    private var suggestedNewName: String {
        "cmux-\(workspace.id.uuidString.prefix(8).lowercased())"
    }

    /// Returns true when the effective new-session name is acceptable to tmux.
    private var newNameIsValid: Bool {
        let name = effectiveNewName
        return name.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "tmux.picker.title", defaultValue: "Connect to tmux Session"))
                .font(.title3.weight(.semibold))

            Text(
                String(
                    localized: "tmux.picker.subtitle",
                    defaultValue: "This remote host has tmux. Select a session to attach to, or create a new one. Your shells will survive network disconnects."
                )
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !workspace.remoteTmuxSessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "tmux.picker.existing", defaultValue: "Existing sessions"))
                        .font(.subheadline.weight(.medium))

                    VStack(spacing: 2) {
                        ForEach(workspace.remoteTmuxSessions) { session in
                            Button {
                                guard !isSubmitting else { return }
                                isSubmitting = true
                                // Do NOT call dismiss() here. The sheet is presented via
                                // `showTmuxSessionPicker` and will be dismissed automatically
                                // when `applyRemoteTmuxSession` sets that flag to false on
                                // a successful attach. This keeps the picker open if attach fails.
                                workspace.selectTmuxSession(session.name)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.name)
                                            .font(.system(size: 13, design: .monospaced))
                                        Text(sessionInfoLine(session))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .disabled(isSubmitting)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "tmux.picker.new", defaultValue: "Create new session"))
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    TextField(suggestedNewName, text: $newSessionName)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { createSession() }
                        .disabled(isSubmitting)

                    Button(String(localized: "tmux.picker.create", defaultValue: "Create")) {
                        createSession()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || !newNameIsValid)
                }

                if !newSessionName.isEmpty && !newNameIsValid {
                    Text(String(
                        localized: "tmux.picker.invalid_name",
                        defaultValue: "Session names may only contain letters, digits, - and _."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "tmux.picker.skip", defaultValue: "Skip")) {
                    // Use skipTmuxPicker() rather than dismiss() so the workspace can
                    // record that the user explicitly opted out. Without this, subsequent
                    // terminal lifecycle events would immediately re-show the picker.
                    workspace.skipTmuxPicker()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: workspace.remoteDaemonStatus) { status in
            // If the daemon reports an error after we submitted, the attach failed.
            // Reset isSubmitting so the user can retry or choose a different session.
            if isSubmitting, status.state == .error {
                isSubmitting = false
            }
        }
    }

    private func sessionInfoLine(_ session: RemoteTmuxSession) -> String {
        let windowPart = session.windows == 1
            ? String(localized: "tmux.picker.windows.one", defaultValue: "1 window")
            : String(format: String(localized: "tmux.picker.windows.many", defaultValue: "%lld windows"),
                     Int64(session.windows))
        if session.attached {
            return windowPart + String(localized: "tmux.picker.attached", defaultValue: " · attached")
        }
        return windowPart
    }

    private var effectiveNewName: String {
        let trimmed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? suggestedNewName : trimmed
    }

    private func createSession() {
        guard !isSubmitting, newNameIsValid else { return }
        let name = effectiveNewName
        guard !name.isEmpty else { return }
        isSubmitting = true
        // Do NOT call dismiss() here. The sheet is dismissed automatically when
        // `applyRemoteTmuxSession` sets `showTmuxSessionPicker = false` on success.
        // This keeps the picker visible (with the spinner) if attachment fails.
        workspace.selectTmuxSession(name)
    }
}
