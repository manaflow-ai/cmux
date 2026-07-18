import AppKit
import CmuxBrowser
import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserDesignModeController {
    typealias ClipboardWriter = @MainActor (String) -> Bool

    static let contentWorld = WKContentWorld.world(name: "cmuxDesignMode")
    static let messageHandlerName = BrowserDesignModeMessageHandler.name
    private static let maximumRequestedChangeCharacters = 4_000

    private(set) var phase: BrowserDesignModePhase = .inactive {
        didSet {
            guard oldValue != phase else { return }
            onActivityChanged()
        }
    }
    private(set) var snapshot: BrowserDesignModeSnapshot?
    private(set) var errorMessage: String?
    var isComposerPresented = false
    /// Exclusive interaction mode: element selection or freehand region draw.
    private(set) var interactionMode: BrowserDesignModeInteractionMode = .select
    /// Bumped whenever the prompt must be wiped (Escape); the token field
    /// clears its storage when it observes a new generation. requestedChange
    /// alone cannot signal this: the field writes storage text back into it.
    private(set) var promptResetGeneration: UInt = 0
    var requestedChange = "" {
        didSet {
            let bounded = String(requestedChange.prefix(Self.maximumRequestedChangeCharacters))
            if requestedChange != bounded {
                requestedChange = bounded
                return
            }
            didCopy = false
        }
    }
    /// The composer prompt's content runs (text and pill order), archived by
    /// the token field so a recreated NSTextView (pane moves rebuild the
    /// overlay) can restore the prompt verbatim. Not observed: only the field
    /// reads and writes it imperatively.
    @ObservationIgnored var promptRuns: [BrowserDesignModePromptRun] = []
    private(set) var isCopying = false
    private(set) var didCopy = false

    @ObservationIgnored private let surfaceID: UUID
    @ObservationIgnored private let script: BrowserDesignModeScript
    @ObservationIgnored private let promptFormatter: BrowserDesignModePromptFormatter
    @ObservationIgnored private let screenshotStore: BrowserDesignModeScreenshotStore
    @ObservationIgnored private let javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator
    @ObservationIgnored private let screenshotEvaluator: BrowserDesignModeScreenshotEvaluator
    @ObservationIgnored private let canEnable: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let clipboardWriter: ClipboardWriter
    @ObservationIgnored private let onActivityChanged: @MainActor @Sendable () -> Void
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var messageHandler: BrowserDesignModeMessageHandler?
    @ObservationIgnored private var operationRevision: UInt = 0
    @ObservationIgnored private var activePageURL: URL?
    @ObservationIgnored private var copyTask: Task<Void, Never>?
    @ObservationIgnored private var copyTaskID: UUID?
    var isActive: Bool { phase == .active || phase == .activating }
    var protectsFromDiscard: Bool { phase != .inactive }
    var canToggle: Bool {
        guard phase != .activating, phase != .deactivating else { return false }
        return phase == .active || canEnable()
    }
    var canCopy: Bool {
        phase == .active
            && snapshot?.selections.isEmpty == false
            && copyTask == nil
            && !isCopying
    }
    var unavailableMessage: String? {
        guard !isActive, !canEnable() else { return nil }
        return String(
            localized: "browser.designMode.error.noPage",
            defaultValue: "Open a page before entering Design Mode."
        )
    }

    init(
        surfaceID: UUID,
        script: BrowserDesignModeScript,
        promptFormatter: BrowserDesignModePromptFormatter,
        screenshotStore: BrowserDesignModeScreenshotStore,
        javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator,
        screenshotEvaluator: BrowserDesignModeScreenshotEvaluator,
        canEnable: @escaping @MainActor @Sendable () -> Bool,
        clipboardWriter: @escaping ClipboardWriter,
        onActivityChanged: @escaping @MainActor @Sendable () -> Void
    ) {
        self.surfaceID = surfaceID
        self.script = script
        self.promptFormatter = promptFormatter
        self.screenshotStore = screenshotStore
        self.javaScriptEvaluator = javaScriptEvaluator
        self.screenshotEvaluator = screenshotEvaluator
        self.canEnable = canEnable
        self.clipboardWriter = clipboardWriter
        self.onActivityChanged = onActivityChanged
    }

    func install(on webView: WKWebView) {
        if let installed = self.webView, installed !== webView {
            invalidateOperation()
            bestEffortRuntimeCleanup(in: installed)
            uninstall(from: installed)
            resetNativeState()
        }
        self.webView = webView
        let handler = BrowserDesignModeMessageHandler(
            onSnapshot: { [weak self] data in
                self?.receiveSnapshotData(data)
            },
            onExitRequested: { [weak self] in
                guard let self, self.isActive else { return }
                Task { @MainActor in
                    await self.setEnabled(false, reason: "escape")
                }
            },
            onPromptReset: { [weak self] in
                guard let self, self.isActive else { return }
                self.requestedChange = ""
                self.promptRuns = []
                self.promptResetGeneration &+= 1
                self.didCopy = false
                self.errorMessage = nil
            }
        )
        messageHandler = handler
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(
            forName: Self.messageHandlerName,
            contentWorld: Self.contentWorld
        )
        controller.add(
            handler,
            contentWorld: Self.contentWorld,
            name: Self.messageHandlerName
        )
    }

    func webViewWillNavigate() {
        guard isActive || snapshot != nil else { return }
        invalidateOperation()
        if let webView { bestEffortRuntimeCleanup(in: webView) }
        resetNativeState()
    }

    func webViewURLDidChange(to url: URL?) {
        guard (isActive || snapshot != nil), url != activePageURL else { return }
        webViewWillNavigate()
    }

    func webViewWillBeRemoved(_ webView: WKWebView) {
        invalidateOperation()
        bestEffortRuntimeCleanup(in: webView)
        resetNativeState()
        uninstall(from: webView)
        if self.webView === webView { self.webView = nil }
    }

    @discardableResult
    func toggle(reason: String) async -> Bool {
        await setEnabled(!isActive, reason: reason)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, reason: String) async -> Bool {
        _ = reason
        guard phase != .activating, phase != .deactivating else { return false }
        if enabled {
            guard phase != .active else { return true }
            guard canEnable(), let webView else {
                errorMessage = String(
                    localized: "browser.designMode.error.noPage",
                    defaultValue: "Open a page before entering Design Mode."
                )
                isComposerPresented = true
                return false
            }
            phase = .activating
            activePageURL = webView.url
            let operation = beginOperation()
            errorMessage = nil
            do {
                let source = try await script.source()
                guard operation == operationRevision else { return false }
                let value = try await evaluate(
                    """
                    \(source)
                    return globalThis.__cmuxDesignMode.enable();
                    """,
                    in: webView
                )
                guard operation == operationRevision else { return false }
                let next = try BrowserDesignModeSupport.decodeSnapshot(value)
                apply(next)
                phase = .active
                // The composer docks bottom-center from the moment Design
                // Mode activates and stays until Escape or deactivation.
                isComposerPresented = true
                return true
            } catch let enableError {
                guard operation == operationRevision else { return false }
                if enableError is CancellationError || enableError as? BrowserDesignModeError == .operationTimedOut {
                    invalidateOperation()
                    bestEffortRuntimeCleanup(in: webView)
                    resetNativeState()
                    BrowserDesignModeSupport.record(enableError, operation: "enable")
                    errorMessage = String(
                        localized: "browser.designMode.error.enable",
                        defaultValue: "Design Mode could not start."
                    )
                    isComposerPresented = true
                    return false
                }
                let cleanupSucceeded: Bool
                do {
                    try await destroyRuntime(in: webView)
                    cleanupSucceeded = true
                } catch {
                    cleanupSucceeded = false
                }
                if cleanupSucceeded {
                    resetNativeState()
                } else {
                    phase = .active
                }
                BrowserDesignModeSupport.record(enableError, operation: "enable")
                errorMessage = String(
                    localized: "browser.designMode.error.enable",
                    defaultValue: "Design Mode could not start."
                )
                isComposerPresented = true
                return false
            }
        }

        guard phase != .inactive else { return true }
        phase = .deactivating
        invalidateOperation()
        let operation = operationRevision
        errorMessage = nil
        do {
            if let webView { try await destroyRuntime(in: webView) }
            guard operation == operationRevision else { return false }
            resetNativeState()
            return true
        } catch let disableError {
            guard operation == operationRevision else { return false }
            phase = .active
            BrowserDesignModeSupport.record(disableError, operation: "disable")
            errorMessage = String(
                localized: "browser.designMode.error.disable",
                defaultValue: "Design Mode cleanup failed. Reload the page or try again."
            )
            isComposerPresented = true
            return false
        }
    }

    func copySelection() async {
        if let copyTask {
            await copyTask.value
            return
        }
        guard canCopy else { return }
        isCopying = true
        didCopy = false
        let taskID = UUID()
        copyTaskID = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCopySelection()
        }
        copyTask = task
        await task.value
        guard copyTaskID == taskID else { return }
        copyTask = nil
        copyTaskID = nil
        isCopying = false
    }

    /// Escape semantics shared by the page and the composer: with any pills
    /// or typed text, reset the whole prompt; with a clean slate, leave
    /// Design Mode.
    func handleEscape() async {
        guard phase == .active else { return }
        let hasContent = snapshot?.selections.isEmpty == false || !requestedChange.isEmpty
        if hasContent {
            requestedChange = ""
            promptRuns = []
            promptResetGeneration &+= 1
            didCopy = false
            errorMessage = nil
            guard let webView else { return }
            if let value = try? await evaluate(
                "return globalThis.__cmuxDesignMode?.clearSelection();",
                arguments: [:],
                in: webView
            ), let next = try? BrowserDesignModeSupport.decodeSnapshot(value) {
                apply(next)
            }
        } else {
            await setEnabled(false, reason: "escape")
        }
    }

    /// Clears the page-side hover highlight (used when the pointer enters the
    /// native composer card, which the page cannot observe).
    func clearPageHover() async {
        guard phase == .active, let webView else { return }
        _ = try? await evaluate(
            "return globalThis.__cmuxDesignMode?.clearHover();",
            arguments: [:],
            in: webView
        )
    }

    /// Mouse-move-rate entry point for hover clearing: coalesces the calls
    /// the card's tracking area produces into at most a few evaluations per
    /// second.
    func clearPageHoverThrottled() {
        let now = ContinuousClock.now
        if let last = lastHoverClearAt, now - last < .milliseconds(200) { return }
        lastHoverClearAt = now
        Task { @MainActor in await self.clearPageHover() }
    }
    @ObservationIgnored private var lastHoverClearAt: ContinuousClock.Instant?

    /// Publishes the composer card's frame (webview viewport coordinates) to
    /// the page runtime, which treats that region as hover-dead. The webview's
    /// tracking area receives mouse moves over the native card regardless of
    /// z-order, so the runtime must know where the card is.
    func updateComposerFrame(_ frame: CGRect) {
        guard frame != lastPublishedComposerFrame else { return }
        lastPublishedComposerFrame = frame
        guard phase == .active, let webView else { return }
        Task { @MainActor in
            _ = try? await self.evaluate(
                "return globalThis.__cmuxDesignMode?.setComposerFrame(x, y, w, h);",
                arguments: [
                    "x": frame.origin.x,
                    "y": frame.origin.y,
                    "w": frame.width,
                    "h": frame.height,
                ],
                in: webView
            )
        }
    }
    @ObservationIgnored private var lastPublishedComposerFrame: CGRect?

    /// Flashes the outline of the selection at `index` on the page.
    func revealSelection(at index: Int) async {
        guard phase == .active,
              snapshot?.selections.indices.contains(index) == true,
              let webView else { return }
        _ = try? await evaluate(
            "return globalThis.__cmuxDesignMode?.flashSelection(index);",
            arguments: ["index": index],
            in: webView
        )
    }

    func setInteractionMode(_ mode: BrowserDesignModeInteractionMode) async {
        guard phase == .active, mode != interactionMode, let webView else { return }
        interactionMode = mode
        do {
            let value = try await evaluate(
                "return globalThis.__cmuxDesignMode?.setMode(mode);",
                arguments: ["mode": mode.rawValue],
                in: webView
            )
            apply(try BrowserDesignModeSupport.decodeSnapshot(value))
        } catch {
            BrowserDesignModeSupport.record(error, operation: "setMode")
        }
    }

    func removeSelection(at index: Int) async {
        guard phase == .active,
              snapshot?.selections.indices.contains(index) == true,
              let webView else { return }
        do {
            let value = try await evaluate(
                "return globalThis.__cmuxDesignMode?.removeSelection(index);",
                arguments: ["index": index],
                in: webView
            )
            let next = try BrowserDesignModeSupport.decodeSnapshot(value)
            apply(next)
            didCopy = false
            errorMessage = nil
        } catch {
            BrowserDesignModeSupport.record(error, operation: "removeSelection")
            errorMessage = BrowserDesignModeSupport.productMessage(
                for: error,
                fallback: String(
                    localized: "browser.designMode.error.updateSelection",
                    defaultValue: "Could not update the selected elements."
                )
            )
            isComposerPresented = true
        }
    }

    func presentError(_ message: String) {
        errorMessage = message
        isComposerPresented = true
    }

    func dismissComposer() {
        isComposerPresented = false
    }

    private func performCopySelection() async {
        let requestedChange = requestedChange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .active,
              snapshot?.selections.isEmpty == false,
              let webView else { return }
        let operation = beginOperation()
        errorMessage = nil
        do {
            let capture = try await captureStableSelection(in: webView)
            guard operation == operationRevision else { return }
            apply(capture.snapshot)

            guard !capture.snapshot.selections.isEmpty else {
                throw BrowserScreenshotError.invalidSelection
            }
            var screenshotPaths: [String?] = []
            for selection in capture.snapshot.selections {
                do {
                    let crop = try BrowserScreenshotCrop.croppedImage(
                        from: capture.image,
                        selectionInView: BrowserDesignModeSupport.captureRect(
                            selection: selection.bounds,
                            viewport: selection.viewport,
                            viewBounds: capture.viewBounds
                        ),
                        viewBounds: capture.viewBounds
                    )
                    let pngData = try BrowserScreenshotPasteboardWriter.pngData(for: crop)
                    screenshotPaths.append(try await screenshotStore.save(pngData, surfaceID: surfaceID).path)
                } catch BrowserScreenshotError.invalidSelection {
                    screenshotPaths.append(nil)
                }
            }
            guard operation == operationRevision else { return }
            // Full-viewport shot for spatial context (layout around the
            // selections), alongside the per-selection crops.
            var pageScreenshotPath: String?
            if let pagePNG = try? BrowserScreenshotPasteboardWriter.pngData(for: capture.image) {
                pageScreenshotPath = try? await screenshotStore.save(pagePNG, surfaceID: surfaceID).path
            }
            guard operation == operationRevision else { return }
            let pageURL = webView.url?.absoluteString ?? "about:blank"
            let prompt = promptFormatter.format(
                BrowserDesignModePromptContext(
                    pageURL: pageURL,
                    snapshot: capture.snapshot,
                    screenshotPaths: screenshotPaths,
                    requestedChange: requestedChange,
                    pageScreenshotPath: pageScreenshotPath,
                    prompt: promptRuns
                )
            )
            guard !prompt.isEmpty else { throw BrowserDesignModeError.invalidRuntimeResponse }
            guard operation == operationRevision else { return }
            guard clipboardWriter(prompt) else { throw BrowserScreenshotError.pasteboardWriteFailed }
            didCopy = true
        } catch let copyError {
            guard operation == operationRevision else { return }
            BrowserDesignModeSupport.record(copyError, operation: "copy")
            let message = BrowserDesignModeSupport.productMessage(
                for: copyError,
                fallback: String(
                    localized: "browser.designMode.error.copy",
                    defaultValue: "Could not copy the design context."
                )
            )
            errorMessage = message
            isComposerPresented = true
        }
    }

    private func captureStableSelection(
        in webView: WKWebView
    ) async throws -> (snapshot: BrowserDesignModeSnapshot, image: NSImage, viewBounds: NSRect) {
        for _ in 0..<2 {
            let candidate = try await captureCandidate(in: webView)
            if BrowserDesignModeSupport.captureMatches(
                before: candidate.before,
                after: candidate.after,
                beforeViewBounds: candidate.beforeViewBounds,
                afterViewBounds: candidate.afterViewBounds
            ) {
                return (candidate.after, candidate.image, candidate.afterViewBounds)
            }
        }
        throw BrowserDesignModeError.captureChanged
    }

    private func captureCandidate(
        in webView: WKWebView
    ) async throws -> (
        before: BrowserDesignModeSnapshot,
        after: BrowserDesignModeSnapshot,
        image: NSImage,
        beforeViewBounds: NSRect,
        afterViewBounds: NSRect
    ) {
        do {
            let prepared = try await evaluate("return globalThis.__cmuxDesignMode?.prepareCapture();", in: webView)
            let before = try BrowserDesignModeSupport.decodeSnapshot(prepared)
            let beforeViewBounds = webView.bounds
            let image = try await screenshotEvaluator.captureVisibleViewport(from: webView)
            let after = try BrowserDesignModeSupport.decodeSnapshot(
                try await evaluate("return globalThis.__cmuxDesignMode?.snapshot();", in: webView)
            )
            let afterViewBounds = webView.bounds
            try await finishCapture(in: webView)
            return (before, after, image, beforeViewBounds, afterViewBounds)
        } catch {
            let cleanup = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                _ = try? await self.evaluate(
                    "return globalThis.__cmuxDesignMode?.finishCapture();",
                    in: webView
                )
            }
            await cleanup.value
            throw error
        }
    }

    private func finishCapture(in webView: WKWebView) async throws {
        _ = try await evaluate("return globalThis.__cmuxDesignMode?.finishCapture();", in: webView)
    }

    private func destroyRuntime(in webView: WKWebView) async throws {
        _ = try await evaluate("return globalThis.__cmuxDesignMode?.destroy();", in: webView)
    }

    private func evaluate(
        _ body: String,
        arguments: [String: Any] = [:],
        in webView: WKWebView
    ) async throws -> Any? {
        try await javaScriptEvaluator.call(
            body,
            arguments: arguments,
            in: webView,
            contentWorld: Self.contentWorld
        )
    }

    private func receiveSnapshotData(_ data: Data) {
        guard phase == .active || phase == .activating else { return }
        guard let next = try? JSONDecoder().decode(BrowserDesignModeSnapshot.self, from: data) else { return }
        let previousSelectors = snapshot?.selections.map(\.selector)
        apply(next)
        if next.enabled { phase = .active }
        if next.selections.map(\.selector) != previousSelectors {
            errorMessage = nil
            didCopy = false
            // Selection changes only ever OPEN the composer; emptying the
            // prompt never closes it (Escape or deactivation do).
            if !next.selections.isEmpty { isComposerPresented = true }
        }
    }

    private func apply(_ next: BrowserDesignModeSnapshot) {
        guard next.revision >= (snapshot?.revision ?? -1) else { return }
        snapshot = next
    }

    private func uninstall(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName,
            contentWorld: Self.contentWorld
        )
        messageHandler = nil
    }

    private func bestEffortRuntimeCleanup(
        _ body: String = "return globalThis.__cmuxDesignMode?.destroy();",
        in webView: WKWebView
    ) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            _ = try? await self.javaScriptEvaluator.call(
                body,
                arguments: [:],
                in: webView,
                contentWorld: Self.contentWorld
            )
        }
    }

    private func resetNativeState() {
        phase = .inactive
        snapshot = nil
        errorMessage = nil
        isComposerPresented = false
        interactionMode = .select
        requestedChange = ""
        isCopying = false
        didCopy = false
        activePageURL = nil
        copyTask?.cancel()
        // Clear the handle so the next copySelection() starts fresh instead of
        // awaiting a cancelled task and returning without capturing. The
        // originating copySelection() call detects the cleared copyTaskID and
        // leaves the reset state untouched.
        copyTask = nil
        copyTaskID = nil
    }

    private func beginOperation() -> UInt {
        operationRevision &+= 1
        return operationRevision
    }

    private func invalidateOperation() {
        operationRevision &+= 1
        copyTask?.cancel()
        javaScriptEvaluator.cancelAll()
        screenshotEvaluator.cancelAll()
    }

}
