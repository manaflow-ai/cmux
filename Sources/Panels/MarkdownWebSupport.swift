import AppKit
import WebKit

@MainActor
final class WeakMarkdownScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class MarkdownWebView: WKWebView {
    var onPointerDown: (() -> Void)?
#if DEBUG
    var onPortalRenderingStateReattached: ((String) -> Void)?
#endif

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }
}

@MainActor
final class MarkdownWebPortalHostView: NSView {
    var onDidMoveToWindow: (() -> Void)?
    var onGeometryChanged: (() -> Void)?

    override var isOpaque: Bool {
        layer?.isOpaque == true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
        onGeometryChanged?()
    }

    override func layout() {
        super.layout()
        onGeometryChanged?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onGeometryChanged?()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        onGeometryChanged?()
    }
}

#if DEBUG
struct MarkdownRendererDiagnosticsSnapshot: Equatable {
    var makeNSViewCount: Int = 0
    var reuseNSViewCount: Int = 0
    var webViewCreateCount: Int = 0
    var webViewReattachCount: Int = 0
    var updateNSViewCount: Int = 0
    var dismantleRetainedWebViewCount: Int = 0
    var loadShellCount: Int = 0
    var pushMarkdownCount: Int = 0
    var didFinishCount: Int = 0
    var webContentProcessTerminationCount: Int = 0
    var navigationFailureCount: Int = 0
    var portalBindCount: Int = 0
    var portalHideCount: Int = 0

    var existingPanelFlickerSignalCount: Int {
        webViewCreateCount +
            webViewReattachCount +
            dismantleRetainedWebViewCount +
            loadShellCount +
            pushMarkdownCount +
            didFinishCount +
            webContentProcessTerminationCount +
            navigationFailureCount
    }

    func fields(prefix: String, includeExistingPanelFlickerSignalCount: Bool) -> [String: String] {
        var fields = [
            "\(prefix)MakeNSViewCount": String(makeNSViewCount),
            "\(prefix)ReuseNSViewCount": String(reuseNSViewCount),
            "\(prefix)WebViewCreateCount": String(webViewCreateCount),
            "\(prefix)WebViewReattachCount": String(webViewReattachCount),
            "\(prefix)UpdateNSViewCount": String(updateNSViewCount),
            "\(prefix)DismantleRetainedWebViewCount": String(dismantleRetainedWebViewCount),
            "\(prefix)LoadShellCount": String(loadShellCount),
            "\(prefix)PushMarkdownCount": String(pushMarkdownCount),
            "\(prefix)DidFinishCount": String(didFinishCount),
            "\(prefix)WebContentProcessTerminationCount": String(webContentProcessTerminationCount),
            "\(prefix)NavigationFailureCount": String(navigationFailureCount),
            "\(prefix)PortalBindCount": String(portalBindCount),
            "\(prefix)PortalHideCount": String(portalHideCount),
        ]
        if includeExistingPanelFlickerSignalCount {
            fields["\(prefix)FlickerSignalCount"] = String(existingPanelFlickerSignalCount)
        }
        return fields
    }
}
#endif

struct MarkdownWebTheme: Equatable {
    let isDark: Bool
    let background: String
    let mutedBackground: String
    let neutralMutedBackground: String
    let border: String
    let mutedBorder: String

    static func resolve(backgroundColor: NSColor) -> MarkdownWebTheme {
        let base = backgroundColor.markdownOpaqueSRGB
        let isDark = !base.isLightColor
        let overlayColor: NSColor = isDark ? .white : .black
        let muted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.09 : 1.06,
            of: overlayColor
        )
        let neutralMuted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.35 : 1.20,
            of: overlayColor
        )
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.92 : 1.43,
            of: overlayColor
        )
        return MarkdownWebTheme(
            isDark: isDark,
            background: "transparent",
            mutedBackground: muted.markdownCSSColor,
            neutralMutedBackground: neutralMuted.markdownCSSColor,
            border: border.markdownCSSColor,
            mutedBorder: border.withAlphaComponent(border.alphaComponent * 0.70).markdownCSSColor
        )
    }
}

/// Panel-owned renderer session for a markdown preview.
///
/// SwiftUI may recreate `MarkdownWebRenderer` wrappers during split/tab layout
/// updates. The session keeps the WebKit coordinator identity tied to the
/// logical `MarkdownPanel` instead of the transient representable instance.
@MainActor
final class MarkdownRendererSession {
    private let ownedCoordinator = MarkdownWebRenderer.Coordinator()

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        filePath: String
    ) -> MarkdownWebRenderer.Coordinator {
        ownedCoordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        return ownedCoordinator
    }

    func close() {
        ownedCoordinator.close()
    }

    func renderedHTML(markdown: String? = nil) async -> String? {
        await ownedCoordinator.renderedHTML(markdown: markdown)
    }

    func renderedText() async -> String? {
        await ownedCoordinator.renderedText()
    }

    func hidePortal(reason: String) {
        ownedCoordinator.hidePortal(reason: reason)
    }

#if DEBUG
    var diagnosticsSnapshot: MarkdownRendererDiagnosticsSnapshot {
        ownedCoordinator.diagnosticsSnapshot
    }

    var isLoadedForDiagnostics: Bool {
        ownedCoordinator.isLoadedForDiagnostics
    }

    func resetDiagnostics(reason: String) {
        ownedCoordinator.resetDiagnostics(reason: reason)
    }
#endif
}

extension NSColor {
    var markdownOpaqueSRGB: NSColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(1)
    }

    var markdownCSSColor: String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let r = min(255, max(0, Int((red * 255).rounded())))
        let g = min(255, max(0, Int((green * 255).rounded())))
        let b = min(255, max(0, Int((blue * 255).rounded())))
        let a = min(1, max(0, alpha))
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, Double(a))
    }

    func markdownThemeOverlay(targetContrast: CGFloat, of color: NSColor) -> NSColor {
        let base = markdownOpaqueSRGB
        let overlay = color.markdownOpaqueSRGB
        var low: CGFloat = 0
        var high: CGFloat = 1
        var result: CGFloat = 1

        for _ in 0..<18 {
            let mid = (low + high) / 2
            let candidate = base.blended(withFraction: mid, of: overlay) ?? base
            if candidate.markdownContrastRatio(with: base) < Double(targetContrast) {
                low = mid
            } else {
                high = mid
                result = mid
            }
        }

        return overlay.withAlphaComponent(result)
    }

    var markdownRelativeLuminance: Double {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            if value <= 0.04045 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * linear(red)) + (0.7152 * linear(green)) + (0.0722 * linear(blue))
    }

    func markdownContrastRatio(with other: NSColor) -> Double {
        let first = markdownRelativeLuminance
        let second = other.markdownRelativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
