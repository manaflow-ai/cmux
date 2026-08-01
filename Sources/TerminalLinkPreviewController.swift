import AppKit
import Foundation

/// Turns Ghostty's URL-hover stream into one delayed, cancellable live-page
/// preview. The controller owns timing and policy; the pool owns the exact
/// webview that may later move into a real browser panel.
@MainActor
final class TerminalLinkPreviewController {
    typealias TargetResolver = @MainActor (TerminalLinkOpenRequest) -> TerminalLinkOpenCoordinator.PreviewTarget?
    typealias Prewarm = @MainActor (URL, UUID) -> Void
    typealias Attach = @MainActor (
        URL,
        UUID,
        NSView,
        @escaping @MainActor (BrowserPrewarmedWebViewPool.LoadState) -> Void,
        @escaping @MainActor () -> Void
    ) -> BrowserPrewarmedWebViewPool.PreviewAttachment?
    typealias Detach = @MainActor (BrowserPrewarmedWebViewPool.PreviewAttachment) -> Void
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias PreviewOwnsFocus = @MainActor () -> Bool
    typealias ReleasePreviewFocus = @MainActor () -> Void

    private weak var view: TerminalLinkHoverIndicatorView?
    private let targetResolver: TargetResolver
    private let prewarm: Prewarm
    private let attach: Attach
    private let detach: Detach
    private let delayMilliseconds: @MainActor () -> Int
    private let dismissalGraceMilliseconds: Int
    private let animateDismissal: Bool
    private let previewOwnsFocus: PreviewOwnsFocus
    private let releasePreviewFocus: ReleasePreviewFocus
    private let sleep: Sleep

    private var currentRawURL: String?
    private var currentTarget: TerminalLinkOpenCoordinator.PreviewTarget?
    private var currentAnchorPoint = NSPoint.zero
    private var isSourceLinkHovered = false
    private var isPointerInsidePreview = false
    private var isInteractionPinned = false
    private var isDismissalAnimating = false
    private var dwellTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var attachment: BrowserPrewarmedWebViewPool.PreviewAttachment?
    private var generation: UInt64 = 0

    init(
        view: TerminalLinkHoverIndicatorView,
        defaults: UserDefaults = .standard,
        targetResolver: TargetResolver? = nil,
        prewarm: @escaping Prewarm = { url, profileID in
            BrowserPrewarmedWebViewPool.shared.prewarm(url: url, profileID: profileID)
        },
        attach: @escaping Attach = { url, profileID, host, stateDidChange, didDismiss in
            BrowserPrewarmedWebViewPool.shared.attachPreview(
                url: url,
                profileID: profileID,
                to: host,
                stateDidChange: stateDidChange,
                didDismiss: didDismiss
            )
        },
        detach: @escaping Detach = { attachment in
            BrowserPrewarmedWebViewPool.shared.detachPreview(attachment)
        },
        delayMilliseconds: (@MainActor () -> Int)? = nil,
        dismissalGraceMilliseconds: Int = 200,
        animateDismissal: Bool = true,
        previewOwnsFocus: PreviewOwnsFocus? = nil,
        releasePreviewFocus: ReleasePreviewFocus? = nil,
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
    ) {
        self.view = view
        self.targetResolver = targetResolver ?? { request in
            TerminalLinkOpenCoordinator(defaults: defaults).previewTarget(for: request)
        }
        self.prewarm = prewarm
        self.attach = attach
        self.detach = detach
        self.delayMilliseconds = delayMilliseconds ?? {
            BrowserLinkOpenSettings.terminalLinkPreviewHoverDelayMilliseconds(defaults: defaults)
        }
        self.dismissalGraceMilliseconds = dismissalGraceMilliseconds
        self.animateDismissal = animateDismissal
        self.previewOwnsFocus = previewOwnsFocus ?? { [weak view] in
            view?.previewOwnsFirstResponder == true
        }
        self.releasePreviewFocus = releasePreviewFocus ?? { [weak view] in
            view?.resignPreviewFirstResponderIfNeeded()
        }
        self.sleep = sleep
        view.onPreviewPointerChange = { [weak self] isInside in
            self?.previewPointerDidChange(isInside: isInside)
        }
        view.onPreviewPointerDown = { [weak self] isInside in
            self?.previewPointerDidPress(isInside: isInside)
        }
        view.onPreviewWindowResignedKey = { [weak self] in
            self?.previewWindowDidResignKey()
        }
    }

    func update(
        rawURL: String?,
        sourceWorkspaceId: UUID?,
        sourcePanelId: UUID?,
        anchorPoint: NSPoint
    ) {
        let normalizedRawURL = rawURL?.isEmpty == false ? rawURL : nil
        isSourceLinkHovered = normalizedRawURL != nil
        view?.setURL(normalizedRawURL)

        guard let normalizedRawURL else {
            sourceLinkHoverDidEnd()
            return
        }

        cancelPendingDismissalAndRestorePreview()

        let request = TerminalLinkOpenRequest(
            rawValue: normalizedRawURL,
            sourceWorkspaceId: sourceWorkspaceId,
            sourcePanelId: sourcePanelId,
            workingDirectory: nil
        )
        let target = targetResolver(request)

        if currentRawURL == normalizedRawURL, currentTarget == target {
            if view?.isPreviewVisible != true {
                currentAnchorPoint = anchorPoint
            }
            return
        }

        resetPreviewState()
        currentRawURL = normalizedRawURL
        currentTarget = target
        currentAnchorPoint = anchorPoint
        guard target != nil else { return }

        generation &+= 1
        let scheduledGeneration = generation
        let duration = Duration.milliseconds(delayMilliseconds())
        let sleep = sleep
        dwellTask = Task { @MainActor [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.showPreview(generation: scheduledGeneration)
        }
    }

    func invalidate() {
        clear()
        view?.onPreviewPointerChange = nil
        view?.onPreviewPointerDown = nil
        view?.onPreviewWindowResignedKey = nil
    }

    func previewPointerDidChange(isInside: Bool) {
        isPointerInsidePreview = isInside
        guard view?.isPreviewVisible == true else { return }
        if isInside {
            // The card is separated from the source link by a gap, so these
            // two hover regions cannot be active at the same time. Do not
            // depend on Ghostty delivering a final nil event after AppKit has
            // routed pointer events into the webview.
            isSourceLinkHovered = false
            view?.setURL(nil)
            cancelPendingDismissalAndRestorePreview()
        } else if !isSourceLinkHovered,
                  !isInteractionPinned,
                  !previewOwnsFocus() {
            schedulePreviewDismissal()
        }
    }

    func previewPointerDidPress(isInside: Bool) {
        guard view?.isPreviewVisible == true else { return }
        if isInside {
            isInteractionPinned = true
            cancelPendingDismissalAndRestorePreview()
        } else {
            isInteractionPinned = false
            beginPreviewDismissal()
        }
    }

    func previewWindowDidResignKey() {
        guard view?.isPreviewVisible == true else { return }
        isInteractionPinned = false
        beginPreviewDismissal()
    }

    private func showPreview(generation scheduledGeneration: UInt64) {
        dwellTask = nil
        guard generation == scheduledGeneration,
              let target = currentTarget,
              let view,
              view.preparePreview(url: target.url, at: currentAnchorPoint) else {
            return
        }

        prewarm(target.url, target.profileID)
        let attachment = attach(
            target.url,
            target.profileID,
            view.previewWebViewHost,
            { [weak self] state in
                self?.view?.setPreviewLoadState(state)
            },
            { [weak self] in
                self?.poolDidDismiss(generation: scheduledGeneration)
            }
        )
        guard let attachment else {
            beginPreviewDismissal()
            return
        }
        self.attachment = attachment
    }

    private func poolDidDismiss(generation dismissedGeneration: UInt64) {
        guard generation == dismissedGeneration else { return }
        attachment = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        isDismissalAnimating = false
        view?.dismissPreview(animated: false)
    }

    private func clear() {
        isSourceLinkHovered = false
        resetPreviewState()
        currentRawURL = nil
        currentTarget = nil
        view?.setURL(nil)
    }

    private func sourceLinkHoverDidEnd() {
        dwellTask?.cancel()
        dwellTask = nil
        guard view?.isPreviewVisible == true else {
            clear()
            return
        }
        guard !isPointerInsidePreview,
              !isInteractionPinned,
              !previewOwnsFocus() else { return }
        schedulePreviewDismissal()
    }

    private func schedulePreviewDismissal() {
        guard view?.isPreviewVisible == true, dismissalTask == nil, !isDismissalAnimating else { return }
        let scheduledGeneration = generation
        let duration = Duration.milliseconds(max(0, dismissalGraceMilliseconds))
        let sleep = sleep
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.beginPreviewDismissal(generation: scheduledGeneration)
        }
    }

    private func cancelPendingDismissalAndRestorePreview() {
        dismissalTask?.cancel()
        dismissalTask = nil
        if isDismissalAnimating {
            isDismissalAnimating = false
            view?.cancelPreviewDismissal()
        }
    }

    private func beginPreviewDismissal(generation scheduledGeneration: UInt64? = nil) {
        if let scheduledGeneration, scheduledGeneration != generation { return }
        guard view?.isPreviewVisible == true else { return }
        dismissalTask?.cancel()
        dismissalTask = nil
        isDismissalAnimating = true
        let activeGeneration = generation
        view?.dismissPreview(animated: animateDismissal) { [weak self] in
            self?.completePreviewDismissal(generation: activeGeneration)
        }
    }

    private func completePreviewDismissal(generation dismissedGeneration: UInt64) {
        guard generation == dismissedGeneration, isDismissalAnimating else { return }
        isDismissalAnimating = false
        releasePreviewFocus()
        if let attachment {
            self.attachment = nil
            detach(attachment)
        }
        isPointerInsidePreview = false
        isInteractionPinned = false
        generation &+= 1
        if !isSourceLinkHovered {
            currentRawURL = nil
            currentTarget = nil
            view?.setURL(nil)
        }
    }

    private func resetPreviewState() {
        generation &+= 1
        dwellTask?.cancel()
        dwellTask = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        isPointerInsidePreview = false
        isInteractionPinned = false
        isDismissalAnimating = false
        view?.dismissPreview(animated: false)
        if let attachment {
            self.attachment = nil
            detach(attachment)
        }
    }
}
