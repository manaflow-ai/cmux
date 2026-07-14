import AppKit
import CmuxBrowser
import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserDesignModeController {
    static let contentWorld = WKContentWorld.world(name: "cmuxDesignMode")
    static let messageHandlerName = BrowserDesignModeMessageHandler.name

    private(set) var phase: BrowserDesignModePhase = .inactive {
        didSet {
            guard oldValue != phase else { return }
            if phase == .inactive { editorPresented = false }
            onActivityChanged()
        }
    }
    private(set) var snapshot: BrowserDesignModeSnapshot?
    private(set) var handoffState: BrowserDesignModeHandoffState = .idle
    private(set) var errorMessage: String?
    var editorPresented = false

    @ObservationIgnored private let surfaceID: UUID
    @ObservationIgnored private let script: BrowserDesignModeScript
    @ObservationIgnored private let promptFormatter: BrowserDesignModePromptFormatter
    @ObservationIgnored private let screenshotStore: BrowserDesignModeScreenshotStore
    @ObservationIgnored private let javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator
    @ObservationIgnored private let canEnable: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let promptSender: @MainActor @Sendable (
        String,
        Bool,
        @MainActor @Sendable () -> Bool
    ) async throws -> Void
    @ObservationIgnored private let onActivityChanged: @MainActor @Sendable () -> Void
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var messageHandler: BrowserDesignModeMessageHandler?
    @ObservationIgnored private var operationRevision: UInt = 0

    var isActive: Bool {
        phase == .active || phase == .activating
    }

    var canSendToAgent: Bool {
        phase == .active && snapshot?.selection != nil && snapshot?.edits.isEmpty == false
    }

    var protectsFromDiscard: Bool {
        phase != .inactive
    }

    init(
        surfaceID: UUID,
        script: BrowserDesignModeScript,
        promptFormatter: BrowserDesignModePromptFormatter,
        screenshotStore: BrowserDesignModeScreenshotStore,
        javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator,
        canEnable: @escaping @MainActor @Sendable () -> Bool,
        promptSender: @escaping @MainActor @Sendable (
            String,
            Bool,
            @MainActor @Sendable () -> Bool
        ) async throws -> Void,
        onActivityChanged: @escaping @MainActor @Sendable () -> Void
    ) {
        self.surfaceID = surfaceID
        self.script = script
        self.promptFormatter = promptFormatter
        self.screenshotStore = screenshotStore
        self.javaScriptEvaluator = javaScriptEvaluator
        self.canEnable = canEnable
        self.promptSender = promptSender
        self.onActivityChanged = onActivityChanged
    }

    func install(on webView: WKWebView) {
        if let installed = self.webView, installed !== webView {
            invalidateOperation()
            bestEffortDestroyRuntime(in: installed)
            uninstall(from: installed)
            resetNativeState()
        }
        self.webView = webView
        let handler = BrowserDesignModeMessageHandler { [weak self] data in
            self?.receiveSnapshotData(data)
        }
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
        if let webView { bestEffortDestroyRuntime(in: webView) }
        resetNativeState()
    }

    func webViewWillBeRemoved(_ webView: WKWebView) {
        invalidateOperation()
        bestEffortDestroyRuntime(in: webView)
        resetNativeState()
        uninstall(from: webView)
        if self.webView === webView { self.webView = nil }
    }

    @discardableResult
    func toggle(reason: String) async -> Bool {
        await setEnabled(!isActive, reason: reason)
    }

    func presentEditor(reason: String) async {
        if !isActive {
            _ = await setEnabled(true, reason: reason)
        }
        editorPresented = isActive
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
            let operation = beginOperation()
            errorMessage = nil
            handoffState = .idle
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
                let next = try decodeSnapshot(value)
                apply(next)
                phase = .active
                return true
            } catch let enableError {
                guard operation == operationRevision else { return false }
                if enableError as? BrowserDesignModeSendError == .operationTimedOut {
                    invalidateOperation()
                    bestEffortDestroyRuntime(in: webView)
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
        let operation = beginOperation()
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

    func applyStyle(property: String, value: String) async {
        await updateRuntime(
            "return globalThis.__cmuxDesignMode?.applyStyle(property, value);",
            arguments: ["property": property, "value": value]
        )
    }

    func applyText(_ value: String) async {
        await updateRuntime(
            "return globalThis.__cmuxDesignMode?.applyText(value);",
            arguments: ["value": value]
        )
    }

    func revert(editID: String) async {
        await updateRuntime(
            "return globalThis.__cmuxDesignMode?.revert(editID);",
            arguments: ["editID": editID]
        )
    }

    func revertAll() async {
        await updateRuntime("return globalThis.__cmuxDesignMode?.revertAll();")
    }

    func sendToAgent(replacingUnknownDraft: Bool) async {
        guard canSendToAgent, let webView else { return }
        let operation = beginOperation()
        handoffState = .preparing
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
                    screenshotPath: screenshotURL.path
                )
            )
            guard !prompt.isEmpty else { throw BrowserDesignModeSendError.invalidRuntimeResponse }
            try await promptSender(prompt, replacingUnknownDraft) { [weak self] in
                self?.operationRevision == operation
            }
            guard operation == operationRevision else { return }
            handoffState = .sent
        } catch let sendError {
            guard operation == operationRevision else { return }
            recordInternalFailure(sendError, operation: "send")
            let message = productMessage(
                for: sendError,
                fallback: String(
                    localized: "browser.designMode.error.send",
                    defaultValue: "Could not send the design to the agent."
                )
            )
            handoffState = .failed(message)
            errorMessage = message
        }
    }

    private func updateRuntime(_ body: String, arguments: [String: Any] = [:]) async {
        guard phase == .active, let webView else { return }
        let operation = operationRevision
        do {
            let value = try await evaluate(body, arguments: arguments, in: webView)
            guard operation == operationRevision, phase == .active else { return }
            apply(try decodeSnapshot(value))
            errorMessage = nil
            handoffState = .idle
        } catch let updateError {
            guard operation == operationRevision, phase == .active else { return }
            recordInternalFailure(updateError, operation: "edit")
            errorMessage = String(
                localized: "browser.designMode.error.apply",
                defaultValue: "The design change could not be applied."
            )
        }
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
        throw BrowserDesignModeSendError.captureChanged
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
        let prepared = try await evaluate(
            "return globalThis.__cmuxDesignMode?.prepareCapture();",
            in: webView
        )
        do {
            let before = try decodeSnapshot(prepared)
            let beforeViewBounds = webView.bounds
            let image = try await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(from: webView)
            let after = try decodeSnapshot(
                try await evaluate("return globalThis.__cmuxDesignMode?.snapshot();", in: webView)
            )
            let afterViewBounds = webView.bounds
            try await finishCapture(in: webView)
            return (before, after, image, beforeViewBounds, afterViewBounds)
        } catch let captureError {
            try? await finishCapture(in: webView)
            throw captureError
        }
    }

    private static func captureMatches(
        before: BrowserDesignModeSnapshot,
        after: BrowserDesignModeSnapshot,
        beforeViewBounds: NSRect,
        afterViewBounds: NSRect
    ) -> Bool {
        before.enabled && after.enabled
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
        if let error = error as? BrowserDesignModeSendError { return error.localizedDescription }
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
            throw BrowserDesignModeSendError.invalidRuntimeResponse
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(BrowserDesignModeSnapshot.self, from: data)
    }

    private func receiveSnapshotData(_ data: Data) {
        guard phase == .active || phase == .activating else { return }
        guard let next = try? JSONDecoder().decode(BrowserDesignModeSnapshot.self, from: data) else { return }
        apply(next)
        if next.enabled { phase = .active }
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

    private func bestEffortDestroyRuntime(in webView: WKWebView) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            _ = try? await self.javaScriptEvaluator.call(
                "return globalThis.__cmuxDesignMode?.destroy();",
                arguments: [:],
                in: webView,
                contentWorld: Self.contentWorld
            )
        }
    }

    private func resetNativeState() {
        phase = .inactive
        snapshot = nil
        handoffState = .idle
        errorMessage = nil
    }

    private func beginOperation() -> UInt {
        operationRevision &+= 1
        return operationRevision
    }

    private func invalidateOperation() {
        operationRevision &+= 1
        javaScriptEvaluator.cancelAll()
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
