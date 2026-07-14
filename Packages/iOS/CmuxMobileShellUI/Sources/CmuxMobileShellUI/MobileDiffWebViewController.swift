#if os(iOS)
import Foundation
import Observation
import SwiftUI
@preconcurrency import WebKit

/// Main-actor bridge between native viewer controls and `window.cmuxMobileDiff`.
@MainActor
@Observable
final class MobileDiffWebViewController {
    private(set) var isReady = false
    private(set) var errorMessage: String?
    private(set) var currentPath: String
    private(set) var currentIndex: Int
    private(set) var total: Int

    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var pendingScrollPath: String?
    @ObservationIgnored private var desiredLayout: MobileDiffHostPage.Layout
    @ObservationIgnored private var desiredTheme: ColorScheme
    @ObservationIgnored private var sentLayout: MobileDiffHostPage.Layout?
    @ObservationIgnored private var sentTheme: ColorScheme?

    init(
        initialPath: String,
        initialIndex: Int,
        total: Int
    ) {
        currentPath = initialPath
        currentIndex = initialIndex
        self.total = total
        pendingScrollPath = initialPath
        desiredLayout = .unified
        desiredTheme = .light
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        sentLayout = nil
        sentTheme = nil
    }

    func detach(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        self.webView = nil
    }

    func updatePresentation(layout: MobileDiffHostPage.Layout, theme: ColorScheme) {
        desiredLayout = layout
        desiredTheme = theme
        flushPresentation()
    }

    func didBecomeReady() {
        isReady = true
        errorMessage = nil
        flushPresentation()
        flushPendingScroll()
    }

    func didReceiveStats(total: Int?) {
        if let total, total > 0 {
            self.total = total
        }
    }

    func didChangeCurrentFile(path: String, index: Int, total: Int) {
        currentPath = path
        currentIndex = index
        self.total = total
    }

    func requestScroll(path: String, index: Int, total: Int) {
        currentPath = path
        currentIndex = index
        self.total = total
        pendingScrollPath = path
        flushPendingScroll()
    }

    func nextFile() {
        evaluate("window.cmuxMobileDiff?.nextFile()")
    }

    func previousFile() {
        evaluate("window.cmuxMobileDiff?.prevFile()")
    }

    func showError(_ message: String) {
        errorMessage = message
    }

    func reload() {
        guard let webView else { return }
        isReady = false
        errorMessage = nil
        sentLayout = nil
        sentTheme = nil
        pendingScrollPath = currentPath
        webView.reload()
    }

    private func flushPresentation() {
        guard isReady else { return }
        if sentLayout != desiredLayout {
            sentLayout = desiredLayout
            evaluate("window.cmuxMobileDiff?.setLayout('\(desiredLayout.rawValue)')")
        }
        if sentTheme != desiredTheme {
            sentTheme = desiredTheme
            let mode = desiredTheme == .dark ? "dark" : "light"
            evaluate("window.cmuxMobileDiff?.setThemeMode('\(mode)')")
        }
    }

    private func flushPendingScroll() {
        guard isReady, let path = pendingScrollPath else { return }
        pendingScrollPath = nil
        guard let literal = Self.javaScriptStringLiteral(path) else { return }
        evaluate("window.cmuxMobileDiff?.scrollToFile(\(literal))")
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func javaScriptStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else { return nil }
        return String(arrayLiteral.dropFirst().dropLast())
    }
}
#endif
