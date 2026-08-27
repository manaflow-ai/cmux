import AppKit
import CmuxBrowser
import Foundation
import WebKit

/// Owns the selected engine adapter for one browser pane and serializes
/// Chromium profile replacement with the previous child-process shutdown.
@MainActor
final class BrowserPaneEngineController {
    private(set) var adapter: any BrowserPaneEngineAdapter
    private var chromiumSnapshotHandler: ((ChromiumSessionSnapshot) -> Void)?
    private var chromiumFocusHandler: (() -> Void)?
    private let chromiumRuntimeEnvironment: ChromiumBrowserRuntimeEnvironment
    private let chromiumNavigationPolicy: ((URL) -> Bool)?
    private let profileID: UUID
    private let storageID: UUID
    private let remoteDebuggingPort: ChromiumRemoteDebuggingPort
    private let startPrerequisite: Task<Bool, Never>?
    private var initialURL: URL?
    private var didFallbackFromCEF = false

    var kind: BrowserEngineKind { adapter.kind }
    var contentView: NSView? { adapter.contentView }
    var remoteDebuggingEndpoint: BrowserCDPEndpoint? { adapter.remoteDebuggingEndpoint }
    var chromiumStartupReadinessTask: Task<Void, Never>? { adapter.startupReadinessTask }

    init(
        kind: BrowserEngineKind,
        webView: WKWebView,
        profileID: UUID,
        storageID: UUID,
        remoteDebuggingPort: ChromiumRemoteDebuggingPort,
        chromiumRuntimeEnvironment: ChromiumBrowserRuntimeEnvironment,
        chromiumNavigationPolicy: ((URL) -> Bool)? = nil,
        startPrerequisite: Task<Bool, Never>? = nil
    ) {
        self.profileID = profileID
        self.storageID = storageID
        self.remoteDebuggingPort = remoteDebuggingPort
        self.startPrerequisite = startPrerequisite
        self.chromiumRuntimeEnvironment = chromiumRuntimeEnvironment
        self.chromiumNavigationPolicy = chromiumNavigationPolicy
        switch kind {
        case .webkit:
            adapter = WebKitBrowserPaneEngineAdapter(webView: webView)
        case .chromium:
            // Prefer the in-process CEF engine: native GPU rendering with no
            // frame streaming. The child-process streamed engine remains the
            // fallback when the CEF framework is not embedded in this build.
            if CEFRuntimeBootstrap.isRuntimeAvailable {
                let cefAdapter = CEFBrowserPaneEngineAdapter(
                    profileID: profileID,
                    storageID: storageID,
                    remoteDebuggingPort: remoteDebuggingPort,
                    startPrerequisite: startPrerequisite,
                    navigationPolicy: chromiumNavigationPolicy
                )
                adapter = cefAdapter
                cefAdapter.onStartupFailure = { [weak self] in
                    self?.fallbackFromCEF()
                }
            } else {
                adapter = ChromiumBrowserPaneEngineAdapter(
                    profileID: profileID,
                    storageID: storageID,
                    remoteDebuggingPort: remoteDebuggingPort,
                    environment: chromiumRuntimeEnvironment,
                    startPrerequisite: startPrerequisite
                )
            }
        }
    }

    func setChromiumSnapshotHandler(_ handler: @escaping (ChromiumSessionSnapshot) -> Void) {
        chromiumSnapshotHandler = handler
        (adapter as? (any ChromiumEngineAdapting))?.onSnapshot = handler
    }

    func setChromiumFocusHandler(_ handler: @escaping () -> Void) {
        chromiumFocusHandler = handler
        (adapter as? (any ChromiumEngineAdapting))?.onContentFocused = handler
    }

    /// Replaces the managed child and its cmux-owned profile directory. The
    /// engine kind stays Chromium; callers remount the returned host view so
    /// no command can accidentally continue against the old profile.
    @discardableResult
    func replaceChromium(
        profileID: UUID,
        storageID: UUID,
        remoteDebuggingPort: ChromiumRemoteDebuggingPort
    ) -> Bool {
        guard kind == .chromium else { return false }
        let documentScripts = (adapter as? (any ChromiumEngineAdapting))?
            .documentScriptDefinitions() ?? []
        if let oldCEF = adapter as? CEFBrowserPaneEngineAdapter {
            oldCEF.onSnapshot = nil
            let stopTask = Task { @MainActor in
                await oldCEF.stopAndWait()
            }
            let replacement = CEFBrowserPaneEngineAdapter(
                profileID: profileID,
                storageID: storageID,
                remoteDebuggingPort: remoteDebuggingPort,
                documentScripts: documentScripts,
                startPrerequisite: stopTask,
                navigationPolicy: chromiumNavigationPolicy
            )
            replacement.onSnapshot = chromiumSnapshotHandler
            replacement.onContentFocused = chromiumFocusHandler
            adapter = replacement
            return true
        }
        if let oldChromium = adapter as? ChromiumBrowserPaneEngineAdapter {
            // Detach the callback before stopping so a queued stopped snapshot
            // from the old profile cannot overwrite the replacement.
            oldChromium.onSnapshot = nil
            let stopTask = oldChromium.beginStop()
            let replacement = ChromiumBrowserPaneEngineAdapter(
                profileID: profileID,
                storageID: storageID,
                remoteDebuggingPort: remoteDebuggingPort,
                environment: chromiumRuntimeEnvironment,
                documentScripts: documentScripts,
                startPrerequisite: stopTask
            )
            replacement.onSnapshot = chromiumSnapshotHandler
            replacement.onContentFocused = chromiumFocusHandler
            adapter = replacement
            return true
        }
        adapter.stop()
        let replacement = ChromiumBrowserPaneEngineAdapter(
            profileID: profileID,
            storageID: storageID,
            remoteDebuggingPort: remoteDebuggingPort,
            environment: chromiumRuntimeEnvironment,
            documentScripts: documentScripts
        )
        replacement.onSnapshot = chromiumSnapshotHandler
        replacement.onContentFocused = chromiumFocusHandler
        adapter = replacement
        return true
    }

    func start(initialURL: URL?) {
        self.initialURL = initialURL
        adapter.start(initialURL: initialURL)
    }

    /// Replaces an unusable embedded CEF runtime with the streamed child
    /// engine while preserving the pane's profile, callbacks, and URL.
    private func fallbackFromCEF() {
        guard !didFallbackFromCEF,
              let oldCEF = adapter as? CEFBrowserPaneEngineAdapter else { return }
        didFallbackFromCEF = true
        oldCEF.onStartupFailure = nil
        oldCEF.onSnapshot = nil
        let stopTask = Task { @MainActor in
            await oldCEF.stopAndWait()
        }
        let replacement = ChromiumBrowserPaneEngineAdapter(
            profileID: profileID,
            storageID: storageID,
            remoteDebuggingPort: remoteDebuggingPort,
            environment: chromiumRuntimeEnvironment,
            documentScripts: oldCEF.documentScriptDefinitions(),
            startPrerequisite: stopTask
        )
        replacement.onSnapshot = chromiumSnapshotHandler
        replacement.onContentFocused = chromiumFocusHandler
        adapter = replacement
        replacement.start(initialURL: initialURL)
    }

    func waitForStartupReadiness() async {
        await adapter.startupReadinessTask?.value
    }

    func stop() {
        adapter.stop()
    }

    /// Stops an engine at its completed lifecycle boundary when it exposes
    /// asynchronous teardown (CEF); synchronous engines stop immediately.
    @discardableResult
    func stopAndWait() async -> Bool {
        if let cef = adapter as? CEFBrowserPaneEngineAdapter {
            return await cef.stopAndWait()
        } else if let chromium = adapter as? ChromiumBrowserPaneEngineAdapter {
            return await chromium.stopAndWait()
        } else {
            adapter.stop()
            return true
        }
    }
}
