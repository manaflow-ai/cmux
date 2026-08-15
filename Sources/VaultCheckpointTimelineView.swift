import SwiftUI

/// Checkpoint timeline for one session, hosted in the transcript peek
/// popover's Checkpoints tab. Derived turn checkpoints come from the
/// transcript (bounded scan); manual ones from `VaultSessionCheckpointStore`.
/// All capabilities arrive as closures — no store references (issue #2586).
struct VaultCheckpointTimelineView: View {
    let entry: SessionEntry
    /// Opens a session in a new tab; used to launch fork-from-checkpoint
    /// results through the exact same path as row resume.
    let onResume: ((SessionEntry) -> Void)?
    let onDismiss: () -> Void

    @State private var derivation: VaultSessionCheckpoints.Derivation?
    @State private var manualCheckpoints: [VaultSessionCheckpoint] = []
    /// Precomputed newest-first merge of derived + manual checkpoints.
    /// Rebuilt only when the sources change, never inside `body` (typing in
    /// the name field re-evaluates `body` every keystroke).
    @State private var mergedCheckpoints: [VaultSessionCheckpoint] = []
    @State private var isLoading = true
    @State private var checkpointName: String = ""
    @State private var isForking = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            checkpointNowRow
            Divider()
            if let errorText {
                errorRow(errorText)
            }
            content
        }
        .task(id: entry.id) {
            await load()
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "sessionIndex.popover.loading", defaultValue: "Loading…"))
                    .cmuxFont(size: 12)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if mergedCheckpoints.isEmpty {
            Text(String(localized: "sessionIndex.checkpoints.empty", defaultValue: "No checkpoints yet"))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if derivation?.isTruncated == true {
                        Text(String(localized: "sessionIndex.checkpoints.truncated",
                                    defaultValue: "Long transcript — earliest turns not shown"))
                            .cmuxFont(size: 11)
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                    ForEach(mergedCheckpoints) { checkpoint in
                        VaultCheckpointRow(
                            checkpoint: checkpoint,
                            isForkEnabled: !isForking,
                            onFork: { fork(checkpoint) }
                        )
                        .equatable()
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var checkpointNowRow: some View {
        HStack(spacing: 6) {
            TextField(
                String(localized: "sessionIndex.checkpoints.namePlaceholder",
                       defaultValue: "Name (optional)"),
                text: $checkpointName
            )
            .textFieldStyle(.plain)
            .cmuxFont(size: 12)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            Button {
                createManualCheckpoint()
            } label: {
                Label(
                    String(localized: "sessionIndex.checkpoints.now", defaultValue: "Checkpoint Now"),
                    systemImage: "flag"
                )
                .cmuxFont(size: 11, weight: .medium)
            }
            .buttonStyle(.borderless)
            .disabled(isLoading || derivation?.lastLineUUID == nil)
            .accessibilityIdentifier("VaultCheckpointNowButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func errorRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .cmuxFont(size: 10)
                .foregroundColor(.orange)
            Text(text)
                .cmuxFont(size: 11)
                .foregroundColor(.primary.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
    }

    private func rebuildMergedCheckpoints() {
        let merged = (derivation?.checkpoints ?? []) + manualCheckpoints
        mergedCheckpoints = merged.sorted { lhs, rhs in
            let l = lhs.timestamp ?? .distantPast
            let r = rhs.timestamp ?? .distantPast
            if l != r { return l > r }
            if lhs.turnIndex != rhs.turnIndex { return lhs.turnIndex > rhs.turnIndex }
            return lhs.id > rhs.id
        }
    }

    // MARK: Actions

    @MainActor
    private func load() async {
        isLoading = true
        errorText = nil
        let fileURL = entry.fileURL
        let agentID = entry.agent.rawValue
        let sessionID = entry.sessionId
        let derived: VaultSessionCheckpoints.Derivation? = await Task.detached(priority: .userInitiated) {
            guard let fileURL else { return nil }
            return VaultSessionCheckpoints.deriveClaudeTurns(fileURL: fileURL)
        }.value
        let manual = await VaultSessionCheckpointStore.shared.checkpoints(
            agentID: agentID,
            sessionID: sessionID
        )
        guard !Task.isCancelled else { return }
        derivation = derived
        manualCheckpoints = manual
        rebuildMergedCheckpoints()
        isLoading = false
    }

    private func createManualCheckpoint() {
        guard let derivation else { return }
        let trimmedName = checkpointName.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentID = entry.agent.rawValue
        let sessionID = entry.sessionId
        let cwd = entry.cwd
        let checkpoint = VaultSessionCheckpoint(
            id: "manual:" + UUID().uuidString.lowercased(),
            source: .manual,
            timestamp: Date(),
            name: trimmedName.isEmpty ? nil : trimmedName,
            turnIndex: derivation.checkpoints.count,
            anchorLineUUID: derivation.lastLineUUID,
            gitSHA: nil,
            promptSnippet: derivation.checkpoints.last?.promptSnippet
        )
        let typedName = checkpointName
        checkpointName = ""
        Task {
            // git HEAD is a bounded file read but still off-main.
            let sha: String? = await Task.detached(priority: .userInitiated) {
                guard let cwd, !cwd.isEmpty else { return nil }
                return VaultGitHeadReader.headSHA(workspacePath: cwd)
            }.value
            let stamped = VaultSessionCheckpoint(
                id: checkpoint.id,
                source: checkpoint.source,
                timestamp: checkpoint.timestamp,
                name: checkpoint.name,
                turnIndex: checkpoint.turnIndex,
                anchorLineUUID: checkpoint.anchorLineUUID,
                gitSHA: sha,
                promptSnippet: checkpoint.promptSnippet
            )
            do {
                let all = try await VaultSessionCheckpointStore.shared.append(
                    stamped,
                    agentID: agentID,
                    sessionID: sessionID
                )
                manualCheckpoints = all
                rebuildMergedCheckpoints()
            } catch {
                // Give the typed name back so a transient failure doesn't
                // eat the user's input.
                checkpointName = typedName
                errorText = String(
                    localized: "sessionIndex.checkpoints.saveFailed",
                    defaultValue: "Couldn't save checkpoint"
                )
            }
        }
    }

    private func fork(_ checkpoint: VaultSessionCheckpoint) {
        guard let parentFileURL = entry.fileURL, !isForking else { return }
        isForking = true
        errorText = nil
        let newSessionID = UUID().uuidString.lowercased()
        let parentEntry = entry
        Task {
            do {
                let forkedURL = try await Task.detached(priority: .userInitiated) {
                    try VaultCheckpointForker.forkClaudeTranscript(
                        parentFileURL: parentFileURL,
                        checkpoint: checkpoint,
                        newSessionID: newSessionID
                    )
                }.value
                isForking = false
                let forked = parentEntry.forkedClaudeEntry(
                    newSessionID: newSessionID,
                    fileURL: forkedURL,
                    now: Date()
                )
                onResume?(forked)
                onDismiss()
            } catch {
                isForking = false
                let detail = (error as? VaultCheckpointForkError)?.localizedSummary
                    ?? String(localized: "sessionIndex.checkpoints.error.unknown",
                              defaultValue: "An unexpected error occurred")
                let format = String(
                    localized: "sessionIndex.checkpoints.forkFailed",
                    defaultValue: "Couldn't fork: %@"
                )
                errorText = String(format: format, detail)
            }
        }
    }
}

/// One checkpoint line: source icon, name/snippet, relative time, short sha.
private struct VaultCheckpointRow: View, Equatable {
    let checkpoint: VaultSessionCheckpoint
    let isForkEnabled: Bool
    let onFork: () -> Void
    @State private var isHovered = false

    static func == (lhs: VaultCheckpointRow, rhs: VaultCheckpointRow) -> Bool {
        lhs.checkpoint == rhs.checkpoint && lhs.isForkEnabled == rhs.isForkEnabled
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: checkpoint.source == .manual ? "flag.fill" : "circle.fill")
                .cmuxFont(size: checkpoint.source == .manual ? 10 : 5)
                .foregroundColor(checkpoint.source == .manual ? .accentColor : .secondary.opacity(0.5))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .cmuxFont(size: 12)
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(subtitleText)
                        .cmuxFont(size: 10)
                        .foregroundColor(.secondary.opacity(0.7))
                    if let sha = checkpoint.gitSHA {
                        Button {
                            GhosttyApp.terminalPasteboard.writeString(sha, to: .general)
                        } label: {
                            Label(String(sha.prefix(7)), systemImage: "doc.on.doc")
                                .cmuxFont(size: 10, monospacedDigit: true)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "sessionIndex.checkpoints.copySha",
                                     defaultValue: "Copy commit SHA"))
                    }
                }
            }
            Spacer(minLength: 6)
            // Always present (not hover-gated) so keyboard and VoiceOver
            // users can reach the timeline's primary action; hover only
            // raises its prominence.
            Button {
                onFork()
            } label: {
                Text(String(localized: "sessionIndex.checkpoints.forkFromHere",
                            defaultValue: "Fork from Here"))
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(isHovered ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!isForkEnabled)
            .help(String(localized: "sessionIndex.checkpoints.restoreHint",
                         defaultValue: "Restore rewinds by forking a new session — the original session is never modified"))
            .accessibilityIdentifier("VaultCheckpointForkButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                .padding(.horizontal, 6)
        )
        .onHover { isHovered = $0 }
    }

    private var titleText: String {
        if let name = checkpoint.name, !name.isEmpty {
            return name
        }
        if let snippet = checkpoint.promptSnippet, !snippet.isEmpty {
            return snippet
        }
        return checkpoint.source == .manual
            ? String(localized: "sessionIndex.checkpoints.manualLabel", defaultValue: "Manual checkpoint")
            : turnLabel
    }

    private var subtitleText: String {
        var parts: [String] = [turnLabel]
        if let timestamp = checkpoint.timestamp {
            parts.append(
                SessionIndexView.relativeFormatter.localizedString(for: timestamp, relativeTo: Date())
            )
        }
        return parts.joined(separator: " · ")
    }

    private var turnLabel: String {
        let format = String(
            localized: "sessionIndex.checkpoints.turnLabel",
            defaultValue: "Turn %lld"
        )
        return String(format: format, checkpoint.turnIndex)
    }
}
