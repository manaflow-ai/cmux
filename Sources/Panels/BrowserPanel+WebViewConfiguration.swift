import AppKit
import CmuxBrowser
import WebKit

extension BrowserPanel {
    static func configureWebViewConfiguration(
        _ configuration: WKWebViewConfiguration,
        websiteDataStore: WKWebsiteDataStore
    ) {
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Ensure browser cookies/storage persist across navigations and launches.
        // This reduces repeated consent/bot-challenge flows on sites like Google.
        configuration.websiteDataStore = websiteDataStore
        // Safari Web Extensions installed under ~/.config/cmux/browser-extensions
        // (macOS 15.4+; no-op when the directory is empty).
        if #available(macOS 15.4, *), let extensionsManager = BrowserWebExtensionsManager.shared {
            configuration.webExtensionController = extensionsManager.controller
        }
        if configuration.urlSchemeHandler(forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(
                CmuxDiffViewerURLSchemeHandler.shared,
                forURLScheme: CmuxDiffViewerURLSchemeHandler.scheme
            )
        }
        // Review-comment persistence + TextBox attach for diff viewer pages.
        // The handler itself rejects every frame that is not a registered diff
        // viewer session, so installing it on all browser webviews is safe.
        DiffCommentsBridge.installIfNeeded(on: configuration.userContentController)

        // Enable developer extras (DevTools)
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.preferences.isElementFullscreenEnabled = true

        // Enable JavaScript
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserFileSystemAccessBridge.scriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Keep browser console/error/dialog telemetry active from document start on every navigation.
        // Main frame only — injecting into cross-origin iframes causes CAPTCHA providers
        // (reCAPTCHA, hCaptcha, Cloudflare Turnstile) to detect the overridden console.*
        // methods and __cmux* globals as environment tampering, failing the challenge.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.telemetryHookBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: RemoteLoopbackRuntimeBridge.runtimeBridgeScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.addUserScript(WKUserScript(source: BrowserWebAuthnBridgeContract.relayScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: BrowserWebAuthnBridgeContract.contentWorld)); configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserWebAuthnBridgeContract.scriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
        // Track the last editable focused element continuously so omnibar exit can
        // restore page input focus even if capture runs after first-responder handoff.
        // Main frame only — same CAPTCHA interference concern as telemetry hooks.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserOmnibarPageFocusRepository.trackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Keep a native cache of whether the focused page element can currently accept
        // plain-text paste so Cmd+Shift+V is only consumed when the browser can use it.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: CmuxWebView.pasteAsPlainTextFocusTrackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Report <video>/<audio> playback so a hidden pane with actively-playing
        // media is exempted from memory discard
        // (https://github.com/manaflow-ai/cmux/issues/5409). Injected into every
        // frame so embedded players in cross-origin iframes keep the pane alive
        // too. Runs in an isolated content world (shared DOM, separate JS scope)
        // so the handler is hidden from page JavaScript that could otherwise post
        // a fake playing report; this also keeps it clear of CAPTCHA fingerprint
        // checks in those iframes.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.mediaPlaybackTrackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: Self.mediaPlaybackContentWorld
            )
        )
    }
}
