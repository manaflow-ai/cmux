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
    @ObservationIgnored private let canEnable: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let promptSender: @MainActor @Sendable (String) throws -> Void
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
        canEnable: @escaping @MainActor @Sendable () -> Bool,
        promptSender: @escaping @MainActor @Sendable (String) throws -> Void,
        onActivityChanged: @escaping @MainActor @Sendable () -> Void
    ) {
        self.surfaceID = surfaceID
        self.script = script
        self.promptFormatter = promptFormatter
        self.screenshotStore = screenshotStore
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
            } catch {
                guard operation == operationRevision else { return false }
                resetNativeState()
                errorMessage = String(
                    format: String(
                        localized: "browser.designMode.error.enableFormat",
                        defaultValue: "Design Mode could not start: %@"
                    ),
                    error.localizedDescription
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
        } catch {
            guard operation == operationRevision else { return false }
            resetNativeState()
            errorMessage = String(
                format: String(
                    localized: "browser.designMode.error.disableFormat",
                    defaultValue: "Design Mode cleanup failed: %@"
                ),
                error.localizedDescription
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

    func sendToAgent() async {
        guard canSendToAgent, let webView else { return }
        let operation = beginOperation()
        handoffState = .preparing
        errorMessage = nil
        do {
            let captureValue = try await evaluate(
                "return globalThis.__cmuxDesignMode?.prepareCapture();",
                in: webView
            )
            let captureSnapshot = try decodeSnapshot(captureValue)
            guard operation == operationRevision else { return }
            apply(captureSnapshot)

            let image: NSImage
            do {
                image = try await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(from: webView)
            } catch {
                try? await finishCapture(in: webView)
                throw error
            }
            try await finishCapture(in: webView)
            guard operation == operationRevision else { return }

            guard let selection = captureSnapshot.selection else {
                throw BrowserScreenshotError.invalidSelection
            }
            let cropRect = Self.captureRect(
                selection: selection.bounds,
                viewport: selection.viewport,
                viewBounds: webView.bounds
            )
            let crop = try BrowserScreenshotCrop.croppedImage(
                from: image,
                selectionInView: cropRect,
                viewBounds: webView.bounds
            )
            let pngData = try BrowserScreenshotPasteboardWriter.pngData(for: crop)
            let screenshotURL = try await screenshotStore.save(pngData, surfaceID: surfaceID)
            guard operation == operationRevision else { return }
            let pageURL = webView.url?.absoluteString ?? "about:blank"
            let prompt = promptFormatter.format(
                BrowserDesignModePromptContext(
                    pageURL: pageURL,
                    snapshot: captureSnapshot,
                    screenshotPath: screenshotURL.path
                )
            )
            guard !prompt.isEmpty else { throw BrowserDesignModeSendError.invalidRuntimeResponse }
            try promptSender(prompt)
            handoffState = .sent
        } catch {
            guard operation == operationRevision else { return }
            let message = String(
                format: String(
                    localized: "browser.designMode.error.sendFormat",
                    defaultValue: "Could not send the design to the agent: %@"
                ),
                error.localizedDescription
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
        } catch {
            guard operation == operationRevision, phase == .active else { return }
            errorMessage = error.localizedDescription
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
        try await webView.callAsyncJavaScript(
            body,
            arguments: arguments,
            in: nil,
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
        Task { @MainActor [weak webView] in
            _ = try? await webView?.callAsyncJavaScript(
                "return globalThis.__cmuxDesignMode?.destroy();",
                arguments: [:],
                in: nil,
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
