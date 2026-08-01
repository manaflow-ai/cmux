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

    private weak var view: TerminalLinkHoverIndicatorView?
    private let targetResolver: TargetResolver
    private let prewarm: Prewarm
    private let attach: Attach
    private let detach: Detach
    private let delayMilliseconds: @MainActor () -> Int
    private let sleep: Sleep

    private var currentRawURL: String?
    private var currentTarget: TerminalLinkOpenCoordinator.PreviewTarget?
    private var currentAnchorPoint = NSPoint.zero
    private var dwellTask: Task<Void, Never>?
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
        self.sleep = sleep
    }

    func update(
        rawURL: String?,
        sourceWorkspaceId: UUID?,
        sourcePanelId: UUID?,
        anchorPoint: NSPoint
    ) {
        let normalizedRawURL = rawURL?.isEmpty == false ? rawURL : nil
        view?.setURL(normalizedRawURL)

        guard let normalizedRawURL else {
            clear()
            return
        }

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
    }

    private func showPreview(generation scheduledGeneration: UInt64) {
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
            view.dismissPreview()
            return
        }
        self.attachment = attachment
    }

    private func poolDidDismiss(generation dismissedGeneration: UInt64) {
        guard generation == dismissedGeneration else { return }
        attachment = nil
        view?.dismissPreview(animated: false)
    }

    private func clear() {
        resetPreviewState()
        currentRawURL = nil
        currentTarget = nil
        view?.setURL(nil)
    }

    private func resetPreviewState() {
        generation &+= 1
        dwellTask?.cancel()
        dwellTask = nil
        view?.dismissPreview(animated: false)
        if let attachment {
            self.attachment = nil
            detach(attachment)
        }
    }
}
