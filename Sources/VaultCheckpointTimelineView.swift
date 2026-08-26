import SwiftUI

/// Checkpoint timeline for one session, hosted in the transcript peek
/// popover's Checkpoints tab. Derived turn checkpoints come from the
/// transcript (bounded scan); manual ones from `VaultSessionCheckpointStore`.
/// All capabilities arrive as closures — no store references (issue #2586).
struct VaultCheckpointTimelineView: View {
    let entry: SessionEntry
    /// Opens a session in a new workspace; used to launch fork-from-checkpoint
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

    /// Whether this entry's harness can produce a truncated fork copy.
    private var supportsFork: Bool {
        VaultCheckpointHarness.resolve(for: entry)?.supportsFork ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            checkpointNowRow
            Divider()
            if let errorText {
                errorRow(errorText)
            }
            if !supportsFork && !isLoading {
                checkpointNotice(
                    systemImage: "info.circle",
                    text: String(localized: "sessionIndex.checkpoints.forkUnavailable",
                                 defaultValue: "Fork from checkpoint isn't available for this agent yet — the timeline is view-only")
                )
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
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "flag")
                    .cmuxFont(size: 18, weight: .regular)
                    .foregroundColor(.secondary.opacity(0.7))
                Text(String(localized: "sessionIndex.checkpoints.empty", defaultValue: "No checkpoints yet"))
                    .cmuxFont(size: 12, weight: .medium)
                    .foregroundColor(.secondary)
                Text(String(localized: "sessionIndex.checkpoints.emptyHint",
                            defaultValue: "Name a point above to make it easy to return here."))
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if derivation?.isTruncated == true {
                        checkpointNotice(
                            systemImage: "exclamationmark.triangle",
                            text: String(localized: "sessionIndex.checkpoints.truncated",
                                         defaultValue: "Long transcript — earliest turns not shown")
                        )
                    }
                    ForEach(mergedCheckpoints) { checkpoint in
                        VaultCheckpointRow(
                            checkpoint: checkpoint,
                            isForkEnabled: !isForking && supportsFork,
                            showsForkButton: supportsFork,
                            onFork: { fork(checkpoint) }
                        )
                        .equatable()
                    }
                }
                .padding(.vertical, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1)
                        .padding(.leading, 19)
                        .padding(.vertical, 8)
                }
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
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            Button {
                createManualCheckpoint()
            } label: {
                Label(
                    String(localized: "sessionIndex.checkpoints.now", defaultValue: "Checkpoint Now"),
                    systemImage: "flag"
                )
                .cmuxFont(size: 11, weight: .semibold)
                .foregroundColor(.accentColor)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.13))
                )
            }
            .buttonStyle(.borderless)
            .disabled(isLoading || derivation == nil)
            .accessibilityIdentifier("VaultCheckpointNowButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func checkpointNotice(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .cmuxFont(size: 11, weight: .medium)
                .foregroundColor(.secondary)
            Text(text)
                .cmuxFont(size: 11)
                .foregroundColor(.secondary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035))
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
        let agentID = entry.agent.rawValue
        let sessionID = entry.sessionId
        // Nonisolated async: the transcript scan runs off the main actor.
        let derived = await VaultCheckpointHarness.derive(for: entry)
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
            anchor: derivation.lastAnchor,
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
                anchor: checkpoint.anchor,
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
        guard !isForking else { return }
        isForking = true
        errorText = nil
        let newSessionID = UUID().uuidString.lowercased()
        let parentEntry = entry
        Task {
            do {
                let forkedURL = try await Task.detached(priority: .userInitiated) {
                    try VaultCheckpointHarness.fork(
                        entry: parentEntry,
                        checkpoint: checkpoint,
                        newSessionID: newSessionID
                    )
                }.value
                isForking = false
                let forked = parentEntry.forkedEntry(
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
    let showsForkButton: Bool
    let onFork: () -> Void
    @State private var isHovered = false

    static func == (lhs: VaultCheckpointRow, rhs: VaultCheckpointRow) -> Bool {
        lhs.checkpoint == rhs.checkpoint
            && lhs.isForkEnabled == rhs.isForkEnabled
            && lhs.showsForkButton == rhs.showsForkButton
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .cmuxFont(size: 12)
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(subtitleText)
                        .cmuxFont(size: 10)
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
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
            if showsForkButton {
                forkButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                .padding(.horizontal, 6)
        )
        .onHover { isHovered = $0 }
    }

    private var marker: some View {
        ZStack {
            Circle()
                .fill(
                    checkpoint.source == .manual
                        ? Color.accentColor
                        : Color.secondary.opacity(0.65)
                )
                .frame(width: checkpoint.source == .manual ? 9 : 7,
                       height: checkpoint.source == .manual ? 9 : 7)
        }
        .frame(width: 14, height: 18, alignment: .top)
    }

    private var forkButton: some View {
        Button {
            onFork()
        } label: {
            Label(
                String(localized: "sessionIndex.checkpoints.forkShort", defaultValue: "Fork"),
                systemImage: "arrow.triangle.branch"
            )
            .cmuxFont(size: 10, weight: .semibold)
            .foregroundColor(isForkEnabled ? .accentColor : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isForkEnabled
                            ? Color.accentColor.opacity(isHovered ? 0.16 : 0.10)
                            : Color.primary.opacity(0.04)
                    )
            )
        }
        .buttonStyle(.borderless)
        .disabled(!isForkEnabled)
        .help(String(localized: "sessionIndex.checkpoints.restoreHint",
                     defaultValue: "Restore rewinds by forking a new session — the original session is never modified"))
        .accessibilityIdentifier("VaultCheckpointForkButton")
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
