import AppKit
import CMUXOwlBrowser
import Foundation
import os
import WebKit

private let browserEngineAdapterLogger = Logger(subsystem: "ai.manaflow.cmux", category: "BrowserEngineAdapter")

enum CmuxBrowserEngineKind: String, Equatable, Sendable {
    case webKit = "webkit"
    case owlChromium = "owl-chromium"
}

enum BrowserEngineCapability: String, CaseIterable, Equatable, Hashable, Sendable {
    case navigation
    case javaScript
    case snapshot
    case focus
    case resize
    case popups
    case downloads
    case contextMenus
    case devTools
    case filePicker
    case permissionPrompts
    case authPrompts
    case passkeys
    case profiles
    case findInPage
    case frameScopedJavaScript
    case viewportEmulation
    case geolocationEmulation
    case offlineEmulation
    case networkInterception
    case tracing
    case screencast
    case touchInput
    case initScripts
}

struct BrowserEngineCapabilities: Equatable, Sendable {
    let supported: Set<BrowserEngineCapability>

    func supports(_ capability: BrowserEngineCapability) -> Bool {
        supported.contains(capability)
    }

    func require(_ capability: BrowserEngineCapability, engineKind: CmuxBrowserEngineKind) throws {
        guard supports(capability) else {
            throw BrowserEngineUnsupportedCapabilityError(engineKind: engineKind, capability: capability)
        }
    }

    var socketPayload: [String: Bool] {
        Dictionary(uniqueKeysWithValues: BrowserEngineCapability.allCases.map { capability in
            (capability.rawValue, supports(capability))
        })
    }
}

struct BrowserEngineDescriptor: Equatable, Sendable {
    let kind: CmuxBrowserEngineKind
    let displayName: String
    let capabilities: BrowserEngineCapabilities
    let runtimeDescription: String?
    let fallbackReason: String?

    static let webKit = BrowserEngineDescriptor(
        kind: .webKit,
        displayName: "WKWebView",
        capabilities: .webKit,
        runtimeDescription: nil,
        fallbackReason: nil
    )

    var socketPayload: [String: Any] {
        [
            "kind": kind.rawValue,
            "display_name": displayName,
            "runtime_description": runtimeDescription ?? NSNull(),
            "fallback_reason": fallbackReason ?? NSNull(),
            "capabilities": capabilities.socketPayload
        ]
    }
}

struct BrowserEngineUnsupportedCapabilityError: LocalizedError, Equatable {
    let engineKind: CmuxBrowserEngineKind
    let capability: BrowserEngineCapability

    var errorDescription: String? {
        String(
            localized: "browser.engine.unsupportedCapability",
            defaultValue: "This browser engine does not support that operation."
        )
    }
}

@MainActor
protocol BrowserEngineAdapter: AnyObject {
    var descriptor: BrowserEngineDescriptor { get }
    var nativeView: NSView { get }
    var currentURL: URL? { get }
    var title: String? { get }
    var isLoading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var estimatedProgress: Double { get }
    var onStateChanged: (() -> Void)? { get set }

    func load(_ request: URLRequest)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    func focus()
    func unfocus()
    func resize(to size: CGSize, scale: CGFloat)
    func evaluateJavaScript(_ script: String) async throws -> Any?
    func evaluateJavaScriptSynchronously(_ script: String) throws -> Any?
    func takeSnapshot(completion: @escaping @Sendable (NSImage?) -> Void)
    func close()
}

extension BrowserEngineCapabilities {
    static let webKit = BrowserEngineCapabilities(supported: [
        .navigation,
        .javaScript,
        .snapshot,
        .focus,
        .resize,
        .popups,
        .downloads,
        .contextMenus,
        .devTools,
        .filePicker,
        .permissionPrompts,
        .authPrompts,
        .passkeys,
        .profiles,
        .findInPage,
        .frameScopedJavaScript,
        .initScripts
    ])

    static let owlChromium = BrowserEngineCapabilities(supported: [
        .navigation,
        .javaScript,
        .snapshot,
        .focus,
        .resize,
        .contextMenus,
        .filePicker,
        .permissionPrompts,
        .authPrompts,
        .profiles
    ])
}

@MainActor
final class BrowserWebKitEngineAdapter: BrowserEngineAdapter {
    let webView: WKWebView
    var descriptor: BrowserEngineDescriptor
    var onStateChanged: (() -> Void)?

    init(webView: WKWebView, fallbackReason: String? = nil) {
        self.webView = webView
        descriptor = BrowserEngineDescriptor(
            kind: .webKit,
            displayName: "WKWebView",
            capabilities: .webKit,
            runtimeDescription: nil,
            fallbackReason: fallbackReason
        )
    }

    var nativeView: NSView { webView }
    var currentURL: URL? { webView.url }
    var title: String? { webView.title }
    var isLoading: Bool { webView.isLoading }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var estimatedProgress: Double { webView.estimatedProgress }

    func load(_ request: URLRequest) {
        browserLoadRequest(request, in: webView)
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func focus() {
        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(webView)
    }

    func unfocus() {
        guard let window = webView.window else { return }
        if browserEngineResponderChainContains(window.firstResponder, target: webView) {
            window.makeFirstResponder(nil)
        }
    }

    func resize(to size: CGSize, scale: CGFloat) {
        _ = size
        _ = scale
    }

    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    func evaluateJavaScriptSynchronously(_ script: String) throws -> Any? {
        throw BrowserEngineUnsupportedCapabilityError(engineKind: .webKit, capability: .javaScript)
    }

    func takeSnapshot(completion: @escaping @Sendable (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            if let error {
                browserEngineAdapterLogger.error(
                    "BrowserPanel snapshot error: \(error.localizedDescription, privacy: .public)"
                )
                completion(nil)
                return
            }
            completion(image)
        }
    }

    func close() {
        webView.stopLoading()
    }
}

@MainActor
final class BrowserOwlChromiumEngineAdapter: BrowserEngineAdapter {
    private let tabID: BrowserTab.ID
    private let engine: BrowserEngine
    private let hostView: OwlWebContentsHostView
    private var latestUpdate: BrowserEngineTabUpdate?
    private var latestURL: URL?

    let descriptor: BrowserEngineDescriptor
    var onStateChanged: (() -> Void)?

    init(profileID: UUID, workspaceID: UUID, configuration: BrowserEngineConfiguration) throws {
        tabID = UUID()
        engine = BrowserEngine(
            configuration: configuration,
            runtimeFactory: { configuration in
                try SwiftContentShellBrowserRuntime(path: configuration.mojoRuntimePath)
            }
        )
        hostView = OwlWebContentsHostView(tabID: tabID, engine: engine, fallbackColor: NSColor.clear.cgColor)
        descriptor = BrowserEngineDescriptor(
            kind: .owlChromium,
            displayName: "Owl 2 Chromium",
            capabilities: .owlChromium,
            runtimeDescription: "SwiftContentShellBrowserRuntime generated Mojo pipe bindings",
            fallbackReason: nil
        )
        engine.onTabUpdate = { [weak self] tabID, update in
            guard let self, tabID == self.tabID else { return }
            self.latestUpdate = update
            self.latestURL = URL(string: update.url)
            self.onStateChanged?()
        }
        _ = profileID
        _ = workspaceID
        try engine.start()
    }

    var nativeView: NSView { hostView }

    var currentURL: URL? {
        latestURL
    }

    var title: String? {
        latestUpdate?.title
    }

    var isLoading: Bool {
        latestUpdate?.isLoading ?? false
    }

    var canGoBack: Bool {
        latestUpdate?.canGoBack ?? false
    }

    var canGoForward: Bool {
        latestUpdate?.canGoForward ?? false
    }

    var estimatedProgress: Double {
        isLoading ? 0.35 : 1.0
    }

    func load(_ request: URLRequest) {
        guard let url = request.url else { return }
        latestURL = url
        hostView.prepareForBrowserNavigationPlaceholder()
        engine.navigate(
            tabID: tabID,
            url: url.absoluteString,
            visibleSize: resolvedVisibleSize(),
            scale: hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        )
        onStateChanged?()
    }

    func goBack() {
        hostView.prepareForBrowserNavigationPlaceholder()
        engine.goBack(tabID: tabID)
    }

    func goForward() {
        hostView.prepareForBrowserNavigationPlaceholder()
        engine.goForward(tabID: tabID)
    }

    func reload() {
        hostView.prepareForBrowserNavigationPlaceholder()
        engine.reload(tabID: tabID)
    }

    func stopLoading() {
        engine.stopLoading(tabID: tabID)
    }

    func focus() {
        guard let window = hostView.window else { return }
        window.makeFirstResponder(hostView)
        engine.setFocus(tabID: tabID, focused: true)
    }

    func unfocus() {
        guard let window = hostView.window else { return }
        if browserEngineResponderChainContains(window.firstResponder, target: hostView) {
            window.makeFirstResponder(nil)
        }
        engine.setFocus(tabID: tabID, focused: false)
    }

    func resize(to size: CGSize, scale: CGFloat) {
        guard size.width >= 1, size.height >= 1 else { return }
        try? engine.resizeImmediately(tabID: tabID, size: size, scale: scale)
    }

    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try evaluateJavaScriptSynchronously(script)
    }

    func evaluateJavaScriptSynchronously(_ script: String) throws -> Any? {
        let raw = try engine.executeJavaScript(tabID: tabID, script: script)
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return raw
        }
        return value
    }

    func takeSnapshot(completion: @escaping @Sendable (NSImage?) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-owl-\(UUID().uuidString).png", isDirectory: false)
        do {
            _ = try engine.captureSurfacePNG(tabID: tabID, to: url)
            completion(NSImage(contentsOf: url))
        } catch {
            browserEngineAdapterLogger.error("BrowserPanel Owl snapshot error: \(String(describing: error), privacy: .public)")
            completion(nil)
        }
    }

    func close() {
        engine.closeTab(tabID)
        engine.shutdown()
    }

    private func resolvedVisibleSize() -> CGSize? {
        let size = hostView.bounds.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        return size
    }
}

@MainActor
enum BrowserEngineAdapterFactory {
    static func makePreferred(
        webView: WKWebView,
        profileID: UUID,
        workspaceID: UUID,
        allowOwlChromium: Bool = true
    ) -> any BrowserEngineAdapter {
        let configuration = cmuxOwlConfiguration(profileID: profileID)
        return makePreferred(
            webView: webView,
            profileID: profileID,
            workspaceID: workspaceID,
            configuration: configuration,
            allowOwlChromium: allowOwlChromium
        )
    }

    static func makePreferred(
        webView: WKWebView,
        profileID: UUID,
        workspaceID: UUID,
        configuration: BrowserEngineConfiguration,
        allowOwlChromium: Bool = true
    ) -> any BrowserEngineAdapter {
        guard allowOwlChromium else {
            return BrowserWebKitEngineAdapter(webView: webView, fallbackReason: "owl_runtime_remote_proxy_unavailable")
        }
        guard configuration.isConfigured,
              FileManager.default.isExecutableFile(atPath: configuration.chromiumHostPath),
              FileManager.default.fileExists(atPath: configuration.mojoRuntimePath) else {
            return BrowserWebKitEngineAdapter(webView: webView, fallbackReason: "owl_runtime_unavailable")
        }
        do {
            return try BrowserOwlChromiumEngineAdapter(
                profileID: profileID,
                workspaceID: workspaceID,
                configuration: configuration
            )
        } catch {
            browserEngineAdapterLogger.error("Owl runtime start failed: \(String(describing: error), privacy: .public)")
            return BrowserWebKitEngineAdapter(
                webView: webView,
                fallbackReason: "owl_runtime_start_failed"
            )
        }
    }

    static func cmuxOwlConfiguration(profileID: UUID) -> BrowserEngineConfiguration {
        let base = BrowserEngineConfiguration.fromEnvironment()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "cmux"
        let userDataRootPath = appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("OwlChromiumProfiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
            .path
        return BrowserEngineConfiguration(
            chromiumHostPath: base.chromiumHostPath,
            mojoRuntimePath: base.mojoRuntimePath,
            userDataRootPath: userDataRootPath,
            devToolsEnabled: false
        )
    }
}

private func browserEngineResponderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
    var responder = start
    var hops = 0
    while let current = responder, hops < 64 {
        if current === target { return true }
        responder = current.nextResponder
        hops += 1
    }
    return false
}
