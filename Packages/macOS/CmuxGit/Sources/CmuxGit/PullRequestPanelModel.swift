import Foundation
import Observation

/// The single main-actor owner of pull-request panel lifecycle, cached display state, and actions.
@MainActor
@Observable
public final class PullRequestPanelModel {
    /// The panel's loading and cached-error state.
    public private(set) var phase: PullRequestPanelPhase = .idle

    /// The current user-action state.
    public private(set) var actionPhase: PullRequestPanelActionPhase = .idle

    /// The merge method selected in the panel picker.
    public var selectedMergeMethod: PullRequestMergeMethod = .squash

    @ObservationIgnored private let service: any PullRequestPanelServing
    @ObservationIgnored private var currentInput: PullRequestWorkspaceInput?
    @ObservationIgnored private var selectedMergeMethodContext: PullRequestPanelContext?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var periodicRefreshTimer: Timer?
    @ObservationIgnored private var mergeabilityRefreshTimer: Timer?

    /// Creates a pull-request panel model.
    /// - Parameter service: The injected GitHub CLI service.
    public init(service: any PullRequestPanelServing) {
        self.service = service
    }

    isolated deinit {
        periodicRefreshTimer?.invalidate()
        mergeabilityRefreshTimer?.invalidate()
    }

    /// Starts or stops visible-only refresh scheduling.
    /// - Parameter visible: Whether the pull-request panel is currently visible.
    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible {
            startPeriodicRefreshTimer()
            scheduleMergeabilityRefreshIfNeeded()
        } else {
            generation &+= 1
            periodicRefreshTimer?.invalidate()
            periodicRefreshTimer = nil
            mergeabilityRefreshTimer?.invalidate()
            mergeabilityRefreshTimer = nil
        }
    }

    /// Activates a repository/branch input, shows any cached content, and refreshes it.
    /// - Parameter input: The selected workspace checkout.
    public func activate(_ input: PullRequestWorkspaceInput) async {
        guard isVisible else { return }
        if currentInput != input {
            currentInput = input
            actionPhase = .idle
            mergeabilityRefreshTimer?.invalidate()
            mergeabilityRefreshTimer = nil
        }

        generation &+= 1
        let activationGeneration = generation
        let cached = await service.cachedContent(for: input)
        guard accepts(activationGeneration, input: input) else { return }
        if let cached {
            updateSelectedMergeMethod(for: cached)
            phase = .refreshing(cached)
        } else {
            phase = .loading
        }
        await resolveRefresh(
            input: input,
            cached: cached,
            activationGeneration: activationGeneration
        )
    }

    /// Manually refreshes the active repository and branch.
    public func refresh() async {
        guard isVisible, !actionPhase.isBusy, let input = currentInput else { return }
        generation &+= 1
        let refreshGeneration = generation
        let cached = phase.displayedContent
        phase = cached.map(PullRequestPanelPhase.refreshing) ?? .loading
        await resolveRefresh(
            input: input,
            cached: cached,
            activationGeneration: refreshGeneration
        )
    }

    /// Merges the displayed pull request immediately or enables auto-merge.
    /// - Parameter whenReady: `true` to enable auto-merge; `false` to merge immediately.
    public func merge(whenReady: Bool) async {
        guard !actionPhase.isBusy,
              case .pullRequest(let snapshot)? = phase.displayedContent else { return }
        let inputAtStart = currentInput
        actionPhase = whenReady ? .enablingAutoMerge : .merging
        do {
            try await service.merge(
                number: snapshot.pullRequest.number,
                context: snapshot.context,
                method: selectedMergeMethod,
                whenReady: whenReady
            )
            guard currentInput == inputAtStart else { return }
            actionPhase = .idle
            await refresh()
        } catch {
            guard currentInput == inputAtStart else { return }
            actionPhase = .failed(serviceError(error, fallback: .mergeFailed))
        }
    }

    /// Disables auto-merge for the displayed pull request.
    public func disableAutoMerge() async {
        guard !actionPhase.isBusy,
              case .pullRequest(let snapshot)? = phase.displayedContent else { return }
        let inputAtStart = currentInput
        actionPhase = .disablingAutoMerge
        do {
            try await service.disableAutoMerge(
                number: snapshot.pullRequest.number,
                context: snapshot.context
            )
            guard currentInput == inputAtStart else { return }
            actionPhase = .idle
            await refresh()
        } catch {
            guard currentInput == inputAtStart else { return }
            actionPhase = .failed(serviceError(error, fallback: .mergeFailed))
        }
    }

    /// Opens GitHub's web pull-request creation flow for the active branch.
    public func createPullRequest() async {
        guard !actionPhase.isBusy,
              case .noPullRequest(let context)? = phase.displayedContent else { return }
        let inputAtStart = currentInput
        actionPhase = .creatingPullRequest
        do {
            try await service.createPullRequest(context: context)
            guard currentInput == inputAtStart else { return }
            actionPhase = .idle
        } catch {
            guard currentInput == inputAtStart else { return }
            actionPhase = .failed(serviceError(error, fallback: .createFailed))
        }
    }

    private func resolveRefresh(
        input: PullRequestWorkspaceInput,
        cached: PullRequestPanelContent?,
        activationGeneration: UInt64
    ) async {
        do {
            let content = try await service.refresh(for: input)
            guard accepts(activationGeneration, input: input) else { return }
            apply(content)
        } catch {
            guard accepts(activationGeneration, input: input) else { return }
            phase = .failed(
                cached: cached,
                error: serviceError(error, fallback: .refreshFailed)
            )
            scheduleMergeabilityRefreshIfNeeded()
        }
    }

    private func apply(_ content: PullRequestPanelContent) {
        phase = .loaded(content)
        updateSelectedMergeMethod(for: content)
        scheduleMergeabilityRefreshIfNeeded()
    }

    private func updateSelectedMergeMethod(for content: PullRequestPanelContent) {
        switch content {
        case .pullRequest(let snapshot):
            if selectedMergeMethodContext != snapshot.context
                || !snapshot.mergeMethods.contains(selectedMergeMethod) {
                selectedMergeMethod = snapshot.mergeMethods.first ?? .squash
            }
            selectedMergeMethodContext = snapshot.context
        case .noPullRequest:
            selectedMergeMethodContext = nil
        }
    }

    private func accepts(_ expectedGeneration: UInt64, input: PullRequestWorkspaceInput) -> Bool {
        isVisible && generation == expectedGeneration && currentInput == input
    }

    private func serviceError(
        _ error: any Error,
        fallback: PullRequestPanelServiceError
    ) -> PullRequestPanelServiceError {
        error as? PullRequestPanelServiceError ?? fallback
    }

    private func startPeriodicRefreshTimer() {
        guard periodicRefreshTimer == nil else { return }
        periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    private func scheduleMergeabilityRefreshIfNeeded() {
        mergeabilityRefreshTimer?.invalidate()
        mergeabilityRefreshTimer = nil
        guard isVisible,
              case .pullRequest(let snapshot)? = phase.displayedContent,
              snapshot.isMergeabilityComputing else { return }
        mergeabilityRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }
}
