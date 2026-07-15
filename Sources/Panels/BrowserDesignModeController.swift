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

    private(set) var phase: BrowserDesignModePhase = .inactive {
        didSet {
            guard oldValue != phase else { return }
            onActivityChanged()
        }
    }
    private(set) var snapshot: BrowserDesignModeSnapshot?
    private(set) var errorMessage: String?

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
            onCopy: { [weak self] requestedChange in
                self?.startCopy(requestedChange: requestedChange)
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
                    return globalThis.__cmuxDesignMode.enable(strings);
                    """,
                    arguments: ["strings": runtimeStrings],
                    in: webView
                )
                guard operation == operationRevision else { return false }
                let next = try decodeSnapshot(value)
                apply(next)
                phase = .active
                return true
            } catch let enableError {
                guard operation == operationRevision else { return false }
                if enableError is CancellationError || enableError as? BrowserDesignModeError == .operationTimedOut {
                    invalidateOperation()
                    bestEffortRuntimeCleanup(in: webView)
                    resetNativeState()
                    recordInternalFailure(enableError, operation: "enable")
                    errorMessage = String(
                        localized: "browser.designMode.error.enable",
                        defaultValue: "Design Mode could not start."
                    )
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
                recordInternalFailure(enableError, operation: "enable")
                errorMessage = String(
                    localized: "browser.designMode.error.enable",
                    defaultValue: "Design Mode could not start."
                )
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
            recordInternalFailure(disableError, operation: "disable")
            errorMessage = String(
                localized: "browser.designMode.error.disable",
                defaultValue: "Design Mode cleanup failed. Reload the page or try again."
            )
            return false
        }
    }

    func copySelection(requestedChange: String) async {
        let requestedChange = requestedChange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .active,
              snapshot?.selection != nil,
              let webView else { return }
        let operation = beginOperation()
        errorMessage = nil
        do {
            let capture = try await captureStableSelection(in: webView)
            guard operation == operationRevision else { return }
            apply(capture.snapshot)

            guard let selection = capture.snapshot.selection else {
                throw BrowserScreenshotError.invalidSelection
            }
            let cropRect = Self.captureRect(
                selection: selection.bounds,
                viewport: selection.viewport,
                viewBounds: capture.viewBounds
            )
            let crop = try BrowserScreenshotCrop.croppedImage(
                from: capture.image,
                selectionInView: cropRect,
                viewBounds: capture.viewBounds
            )
            let pngData = try BrowserScreenshotPasteboardWriter.pngData(for: crop)
            let screenshotURL = try await screenshotStore.save(pngData, surfaceID: surfaceID)
            guard operation == operationRevision else { return }
            let pageURL = webView.url?.absoluteString ?? "about:blank"
            let prompt = promptFormatter.format(
                BrowserDesignModePromptContext(
                    pageURL: pageURL,
                    snapshot: capture.snapshot,
                    screenshotPath: screenshotURL.path,
                    requestedChange: requestedChange
                )
            )
            guard !prompt.isEmpty else { throw BrowserDesignModeError.invalidRuntimeResponse }
            guard operation == operationRevision else { return }
            guard clipboardWriter(prompt) else { throw BrowserScreenshotError.pasteboardWriteFailed }
            await setRuntimeCopyResult(state: "copied", message: nil, in: webView)
        } catch let copyError {
            guard operation == operationRevision else { return }
            recordInternalFailure(copyError, operation: "copy")
            let message = productMessage(
                for: copyError,
                fallback: String(
                    localized: "browser.designMode.error.copy",
                    defaultValue: "Could not copy the design context."
                )
            )
            errorMessage = message
            await setRuntimeCopyResult(state: "failed", message: message, in: webView)
        }
    }

    private func startCopy(requestedChange: String) {
        guard copyTask == nil else { return }
        let taskID = UUID()
        copyTaskID = taskID
        copyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await copySelection(requestedChange: requestedChange)
            guard copyTaskID == taskID else { return }
            copyTask = nil
            copyTaskID = nil
        }
    }

    private func setRuntimeCopyResult(state: String, message: String?, in webView: WKWebView) async {
        _ = try? await evaluate(
            "return globalThis.__cmuxDesignMode?.setCopyResult(state, message);",
            arguments: ["state": state, "message": message ?? NSNull()],
            in: webView
        )
    }

    private func captureStableSelection(
        in webView: WKWebView
    ) async throws -> (snapshot: BrowserDesignModeSnapshot, image: NSImage, viewBounds: NSRect) {
        for _ in 0..<2 {
            let candidate = try await captureCandidate(in: webView)
            if Self.captureMatches(
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
            let before = try decodeSnapshot(prepared)
            let beforeViewBounds = webView.bounds
            let image = try await screenshotEvaluator.captureVisibleViewport(from: webView)
            let after = try decodeSnapshot(try await evaluate("return globalThis.__cmuxDesignMode?.snapshot();", in: webView))
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

    private static func captureMatches(
        before: BrowserDesignModeSnapshot,
        after: BrowserDesignModeSnapshot,
        beforeViewBounds: NSRect,
        afterViewBounds: NSRect
    ) -> Bool {
        before.enabled && after.enabled
            && before.revision == after.revision
            && before.selection?.selector == after.selection?.selector
            && before.selection?.bounds == after.selection?.bounds
            && before.selection?.viewport == after.selection?.viewport
            && beforeViewBounds == afterViewBounds
    }

    private func finishCapture(in webView: WKWebView) async throws {
        _ = try await evaluate("return globalThis.__cmuxDesignMode?.finishCapture();", in: webView)
    }

    private func destroyRuntime(in webView: WKWebView) async throws {
        _ = try await evaluate("return globalThis.__cmuxDesignMode?.destroy();", in: webView)
    }

    private func productMessage(for error: any Error, fallback: String) -> String {
        if let error = error as? BrowserDesignModeError { return error.localizedDescription }
        if let error = error as? BrowserScreenshotError { return error.localizedDescription }
        return fallback
    }

    private func recordInternalFailure(_ error: any Error, operation: String) {
#if DEBUG
        cmuxDebugLog("browser.designMode.\(operation).failed error=\(String(reflecting: error))")
#endif
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

    private func decodeSnapshot(_ value: Any?) throws -> BrowserDesignModeSnapshot {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw BrowserDesignModeError.invalidRuntimeResponse
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(BrowserDesignModeSnapshot.self, from: data)
    }

    private func receiveSnapshotData(_ data: Data) {
        guard phase == .active || phase == .activating else { return }
        guard let next = try? JSONDecoder().decode(BrowserDesignModeSnapshot.self, from: data) else { return }
        let previousSelector = snapshot?.selection?.selector
        apply(next)
        if next.enabled { phase = .active }
        guard let nextSelector = next.selection?.selector, nextSelector != previousSelector else { return }
        errorMessage = nil
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
        activePageURL = nil
        copyTask?.cancel()
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

    private var runtimeStrings: [String: String] {
        [
            "describeChange": String(
                localized: "browser.designMode.composer.describeChange",
                defaultValue: "Describe the change"
            ),
            "copy": String(localized: "browser.designMode.copy", defaultValue: "Copy"),
            "copying": String(
                localized: "browser.designMode.copy.copying",
                defaultValue: "Copying…"
            ),
            "copied": String(
                localized: "browser.designMode.copy.copied",
                defaultValue: "Copied"
            ),
            "copyFailed": String(
                localized: "browser.designMode.error.copy",
                defaultValue: "Could not copy the design context."
            ),
            "removeSelection": String(
                localized: "browser.designMode.composer.removeSelection",
                defaultValue: "Remove selected element"
            ),
            "copyShortcut": String(
                localized: "browser.designMode.copy.shortcut",
                defaultValue: "⌘↩"
            ),
        ]
    }

    private static func captureRect(
        selection: BrowserDesignModeRect,
        viewport: BrowserDesignModeViewport,
        viewBounds: NSRect
    ) -> NSRect {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let scaleX = viewBounds.width / viewport.width
        let scaleY = viewBounds.height / viewport.height
        let width = selection.width * scaleX
        let height = selection.height * scaleY
        return NSRect(
            x: viewBounds.minX + selection.x * scaleX,
            y: viewBounds.maxY - selection.y * scaleY - height,
            width: width,
            height: height
        )
    }
}
