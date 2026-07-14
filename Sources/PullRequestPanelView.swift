import CmuxGit
import SwiftUI

struct PullRequestPanelView: View {
    @State private var model: PullRequestPanelModel
    @State private var isMergeConfirmationPresented = false

    let input: PullRequestWorkspaceInput
    let isVisible: Bool
    let onOpenURL: (URL) -> Void

    init(
        service: any PullRequestPanelServing,
        input: PullRequestWorkspaceInput,
        isVisible: Bool,
        onOpenURL: @escaping (URL) -> Void
    ) {
        _model = State(initialValue: PullRequestPanelModel(service: service))
        self.input = input
        self.isVisible = isVisible
        self.onOpenURL = onOpenURL
    }

    var body: some View {
        phaseContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: PullRequestPanelActivation(input: input, isVisible: isVisible)) {
                model.setVisible(isVisible)
                guard isVisible else { return }
                await model.activate(input)
            }
            .onDisappear {
                model.setVisible(false)
            }
            .confirmationDialog(
                String(localized: "pullRequestPanel.merge.confirm.title", defaultValue: "Merge Pull Request?"),
                isPresented: $isMergeConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(
                    String(localized: "pullRequestPanel.merge.confirm.button", defaultValue: "Merge Pull Request"),
                    role: .destructive
                ) {
                    Task { await model.merge(whenReady: false) }
                }
                Button(
                    String(localized: "common.cancel", defaultValue: "Cancel"),
                    role: .cancel
                ) {}
            } message: {
                Text(String(
                    localized: "pullRequestPanel.merge.confirm.message",
                    defaultValue: "This uses the selected merge method and cannot be undone."
                ))
            }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .idle, .loading:
            centeredState {
                ProgressView()
                Text(String(
                    localized: "pullRequestPanel.loading",
                    defaultValue: "Checking for pull request"
                ))
                .foregroundStyle(.secondary)
            }
        case .loaded(let content), .refreshing(let content):
            displayedContent(content, refreshError: nil)
        case .failed(let cached?, _):
            displayedContent(cached, refreshError: .refreshFailed)
        case .failed(nil, let error):
            failureState(error)
        }
    }

    @ViewBuilder
    private func displayedContent(
        _ content: PullRequestPanelContent,
        refreshError: PullRequestPanelServiceError?
    ) -> some View {
        VStack(spacing: 0) {
            if refreshError != nil {
                cachedRefreshErrorBanner
                Divider()
            }
            switch content {
            case .pullRequest(let snapshot):
                pullRequestContent(snapshot)
            case .noPullRequest(let context):
                noPullRequestContent(context)
            }
        }
    }

    private var cachedRefreshErrorBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                String(
                    localized: "pullRequestPanel.refreshError.title",
                    defaultValue: "Could not refresh pull request"
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            Text(String(
                localized: "pullRequestPanel.refreshError.cachedMessage",
                defaultValue: "GitHub status could not be refreshed. Existing cached data was preserved."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Button(String(localized: "common.refresh", defaultValue: "Refresh")) {
                Task { await model.refresh() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.08))
    }

    private func pullRequestContent(_ snapshot: PullRequestPanelSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pullRequestHeader(snapshot)
                mergeSection(snapshot)
                Divider()
                checksSection(snapshot)
                Divider()
                reviewSection(snapshot)
                actionFailureBanner
            }
            .padding(12)
        }
    }

    private func pullRequestHeader(_ snapshot: PullRequestPanelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(verbatim: "#\(snapshot.pullRequest.number)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                stateBadge(snapshot.pullRequest)
                Spacer(minLength: 0)
                refreshButton
            }
            Button {
                onOpenURL(snapshot.pullRequest.url)
            } label: {
                Text(verbatim: snapshot.pullRequest.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .underline()
            }
            .buttonStyle(.plain)
            .safeHelp(String(
                localized: "pullRequestPanel.openPullRequest.tooltip",
                defaultValue: "Open Pull Request"
            ))
        }
    }

    private func mergeSection(_ snapshot: PullRequestPanelSnapshot) -> some View {
        @Bindable var bindableModel = model
        let hasFreshContent = model.phase.isFresh
        let canMerge = hasFreshContent
            && snapshot.mergeAvailability == .allowed
            && !model.actionPhase.isBusy
        let canConfigureAutoMerge = hasFreshContent
            && snapshot.pullRequest.state.uppercased() == "OPEN"
            && !snapshot.pullRequest.isDraft
            && !model.actionPhase.isBusy

        return VStack(alignment: .leading, spacing: 8) {
            Picker(
                String(localized: "pullRequestPanel.merge.method", defaultValue: "Merge method"),
                selection: $bindableModel.selectedMergeMethod
            ) {
                ForEach(snapshot.mergeMethods, id: \.self) { method in
                    Text(mergeMethodLabel(method)).tag(method)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.actionPhase.isBusy)

            Button {
                isMergeConfirmationPresented = true
            } label: {
                HStack {
                    Spacer(minLength: 0)
                    Text(String(
                        localized: "pullRequestPanel.merge.button",
                        defaultValue: "Merge Pull Request"
                    ))
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canMerge)

            if case .blocked(let reason) = snapshot.mergeAvailability {
                Label(mergeBlockReason(reason), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if snapshot.pullRequest.isAutoMergeEnabled {
                Button(String(
                    localized: "pullRequestPanel.autoMerge.disable",
                    defaultValue: "Disable Auto-Merge"
                )) {
                    Task { await model.disableAutoMerge() }
                }
                .disabled(!canConfigureAutoMerge)
            } else if snapshot.mergeAvailability != .allowed {
                Button(String(
                    localized: "pullRequestPanel.autoMerge.enable",
                    defaultValue: "Enable Auto-Merge"
                )) {
                    Task { await model.merge(whenReady: true) }
                }
                .disabled(!canConfigureAutoMerge)
            }

            if model.actionPhase.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func checksSection(_ snapshot: PullRequestPanelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "pullRequestPanel.checks.title", defaultValue: "Checks"))
                .font(.caption.weight(.semibold))
            Text(checksSummary(snapshot.checksStatus))
                .font(.caption)
                .foregroundStyle(checksSummaryColor(snapshot.checksStatus))
            ForEach(snapshot.checks) { check in
                checkRow(check)
            }
        }
    }

    @ViewBuilder
    private func checkRow(_ check: GitHubPullRequestCheck) -> some View {
        let row = HStack(spacing: 7) {
            checkIcon(check.presentationState)
            Text(verbatim: check.name)
                .lineLimit(2)
            Spacer(minLength: 0)
            if check.link != nil {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)

        if let link = check.link {
            Button { onOpenURL(link) } label: { row }
                .buttonStyle(.plain)
                .safeHelp(String(
                    localized: "pullRequestPanel.check.openTooltip",
                    defaultValue: "Open Check"
                ))
        } else {
            row
        }
    }

    private func reviewSection(_ snapshot: PullRequestPanelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(localized: "pullRequestPanel.review.title", defaultValue: "Review status"))
                .font(.caption.weight(.semibold))
            Label(
                reviewStatus(snapshot.pullRequest.reviewDecision),
                systemImage: reviewStatusIcon(snapshot.pullRequest.reviewDecision)
            )
            .font(.caption)
            if let count = snapshot.unresolvedReviewThreadCount {
                Text(String.localizedStringWithFormat(
                    String(
                        localized: "pullRequestPanel.review.unresolvedThreads",
                        defaultValue: "Unresolved review threads: %lld"
                    ),
                    Int64(count)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionFailureBanner: some View {
        if case .failed = model.actionPhase {
            Label(
                String(
                    localized: "pullRequestPanel.actionError",
                    defaultValue: "The pull request action could not be completed."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
        }
    }

    private func noPullRequestContent(_ context: PullRequestPanelContext) -> some View {
        centeredState {
            refreshButton
                .frame(maxWidth: .infinity, alignment: .trailing)
            Image(systemName: "checklist")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(String(
                localized: "pullRequestPanel.noPullRequest",
                defaultValue: "No pull request found"
            ))
            .font(.headline)
            Text(verbatim: context.branch)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(String(
                localized: "pullRequestPanel.create.button",
                defaultValue: "Create Pull Request"
            )) {
                Task { await model.createPullRequest() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.phase.isFresh || model.actionPhase.isBusy)
            if model.actionPhase.isBusy {
                ProgressView().controlSize(.small)
            }
            actionFailureBanner
        }
    }

    private func failureState(_ error: PullRequestPanelServiceError) -> some View {
        centeredState {
            Image(systemName: failureIcon(error))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(failureMessage(error))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(String(localized: "common.refresh", defaultValue: "Refresh")) {
                Task { await model.refresh() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .disabled(model.actionPhase.isBusy)
        .safeHelp(String(
            localized: "pullRequestPanel.refresh.tooltip",
            defaultValue: "Refresh Pull Request"
        ))
    }

    private func centeredState<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 20)
            content()
            Spacer(minLength: 20)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
