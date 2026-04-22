import AppKit
import Bonsplit
import Combine
import ImageIO
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

private extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8)  & 0xFF) / 255.0,
            blue:  Double( value        & 0xFF) / 255.0
        )
    }
}

private func coloredCircleImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 14, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    image.isTemplate = false
    return image
}

func sidebarActiveForegroundNSColor(
    opacity: CGFloat,
    appAppearance: NSAppearance? = NSApp?.effectiveAppearance
) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let baseColor: NSColor = (bestMatch == .darkAqua) ? .white : .black
    return baseColor.withAlphaComponent(clampedOpacity)
}

func cmuxAccentNSColor(for colorScheme: ColorScheme) -> NSColor {
    switch colorScheme {
    case .dark:
        return NSColor(
            srgbRed: 0,
            green: 145.0 / 255.0,
            blue: 1.0,
            alpha: 1.0
        )
    default:
        return NSColor(
            srgbRed: 0,
            green: 136.0 / 255.0,
            blue: 1.0,
            alpha: 1.0
        )
    }
}

func cmuxAccentNSColor(for appAppearance: NSAppearance?) -> NSColor {
    let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let scheme: ColorScheme = (bestMatch == .darkAqua) ? .dark : .light
    return cmuxAccentNSColor(for: scheme)
}

func cmuxAccentNSColor() -> NSColor {
    NSColor(name: nil) { appearance in
        cmuxAccentNSColor(for: appearance)
    }
}

func cmuxAccentColor() -> Color {
    Color(nsColor: cmuxAccentNSColor())
}

private func sidebarSelectedWorkspaceRelativeLuminance(_ color: NSColor) -> CGFloat {
    let rgbColor = color.usingColorSpace(.sRGB) ?? color
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

    func linearized(_ component: CGFloat) -> CGFloat {
        if component <= 0.03928 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }

    let linearRed = linearized(red)
    let linearGreen = linearized(green)
    let linearBlue = linearized(blue)
    return (0.2126 * linearRed) + (0.7152 * linearGreen) + (0.0722 * linearBlue)
}

private func sidebarSelectedWorkspaceContrastRatio(
    between first: NSColor,
    and second: NSColor
) -> CGFloat {
    let firstLuminance = sidebarSelectedWorkspaceRelativeLuminance(first)
    let secondLuminance = sidebarSelectedWorkspaceRelativeLuminance(second)
    let lighter = max(firstLuminance, secondLuminance)
    let darker = min(firstLuminance, secondLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private func sidebarSelectedWorkspaceReadableBackgroundNSColor(_ color: NSColor) -> NSColor {
    let minimumContrast: CGFloat = 4.5
    var adjusted = color.usingColorSpace(.sRGB) ?? color
    var iteration = 0

    while sidebarSelectedWorkspaceContrastRatio(between: adjusted, and: NSColor.white) < minimumContrast,
          iteration < 12 {
        guard let darkened = adjusted.blended(withFraction: 0.12, of: .black) else { break }
        adjusted = darkened.usingColorSpace(.sRGB) ?? darkened
        iteration += 1
    }

    return adjusted
}

private func sidebarSelectedWorkspaceCustomBackgroundNSColor(
    hex: String,
    colorScheme: ColorScheme
) -> NSColor? {
    guard let color = WorkspaceTabColorSettings.displayNSColor(
        hex: hex,
        colorScheme: colorScheme
    ) else {
        return nil
    }
    return sidebarSelectedWorkspaceReadableBackgroundNSColor(color)
}

struct SidebarRemoteErrorCopyEntry: Equatable {
    let workspaceTitle: String
    let target: String
    let detail: String
}

enum SidebarRemoteErrorCopySupport {
    static func menuLabel(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1 {
            return String(localized: "contextMenu.copyError", defaultValue: "Copy Error")
        }
        return String(localized: "contextMenu.copyErrors", defaultValue: "Copy Errors")
    }

    static func clipboardText(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1, let entry = entries.first {
            return String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.single", defaultValue: "SSH error (%@): %@"),
                entry.target,
                entry.detail
            )
        }

        return entries.enumerated().map { index, entry in
            String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.item", defaultValue: "%lld. %@ (%@): %@"),
                Int64(index + 1),
                entry.workspaceTitle,
                entry.target,
                entry.detail
            )
        }.joined(separator: "\n")
    }
}

func sidebarSelectedWorkspaceBackgroundNSColor(
    for colorScheme: ColorScheme,
    customHex: String? = nil,
    sidebarSelectionColorHex: String? = UserDefaults.standard.string(forKey: "sidebarSelectionColorHex")
) -> NSColor {
    if let customHex,
       let customColor = sidebarSelectedWorkspaceCustomBackgroundNSColor(
        hex: customHex,
        colorScheme: colorScheme
       ) {
        return customColor
    }
    if let hex = sidebarSelectionColorHex,
       let parsed = NSColor(hex: hex) {
        return parsed
    }
    return cmuxAccentNSColor(for: colorScheme)
}

func sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    return NSColor.white.withAlphaComponent(clampedOpacity)
}

struct SidebarWorkspaceRowBackgroundStyle {
    let color: NSColor?
    let opacity: Double

    static let clear = Self(color: nil, opacity: 0)
}

func sidebarWorkspaceRowExplicitRailNSColor(
    activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle,
    customColorHex: String?,
    colorScheme: ColorScheme
) -> NSColor? {
    guard activeTabIndicatorStyle == .leftRail,
          let customColorHex else {
        return nil
    }
    return WorkspaceTabColorSettings.displayNSColor(
        hex: customColorHex,
        colorScheme: colorScheme,
        forceBright: true
    )
}

func sidebarWorkspaceRowBackgroundStyle(
    activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle,
    isActive: Bool,
    isMultiSelected: Bool,
    customColorHex: String?,
    colorScheme: ColorScheme,
    sidebarSelectionColorHex: String?
) -> SidebarWorkspaceRowBackgroundStyle {
    let selectedBackground = sidebarSelectedWorkspaceBackgroundNSColor(
        for: colorScheme,
        sidebarSelectionColorHex: sidebarSelectionColorHex
    )
    let accentBackground = cmuxAccentNSColor(for: colorScheme)
    let customBackground = customColorHex.flatMap {
        WorkspaceTabColorSettings.displayNSColor(
            hex: $0,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        )
    }

    switch activeTabIndicatorStyle {
    case .leftRail:
        if isActive {
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: 1
            )
        }
        if isMultiSelected {
            return SidebarWorkspaceRowBackgroundStyle(color: accentBackground, opacity: 0.25)
        }
        return .clear

    case .solidFill:
        if isActive {
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: 1
            )
        }
        if let customBackground {
            return SidebarWorkspaceRowBackgroundStyle(
                color: customBackground,
                opacity: isMultiSelected ? 0.35 : 0.7
            )
        }
        if isMultiSelected {
            return SidebarWorkspaceRowBackgroundStyle(color: accentBackground, opacity: 0.25)
        }
        return .clear
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
enum InternalTabDragConfigurationProvider {
    // These drags only make sense inside cmux. Outside the app, Finder should
    // reject them instead of materializing placeholder files from the payload.
    static let value = DragConfiguration(
        operationsWithinApp: .init(allowCopy: false, allowMove: true, allowDelete: false),
        operationsOutsideApp: .init(allowCopy: false, allowMove: false, allowDelete: false)
    )
}
#endif

private struct InternalTabDragConfigurationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.dragConfiguration(InternalTabDragConfigurationProvider.value)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func internalOnlyTabDrag() -> some View {
        modifier(InternalTabDragConfigurationModifier())
    }
}

struct ShortcutHintPillBackground: View {
    var emphasis: Double = 1.0

    var body: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.30 * emphasis), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.22 * emphasis), radius: 2, x: 0, y: 1)
    }
}

/// Reusable shortcut hint pill that shows a keyboard shortcut string.
struct ShortcutHintPill: View {
    let text: String
    var fontSize: CGFloat = 9
    var emphasis: Double = 1.0

    init(shortcut: StoredShortcut, fontSize: CGFloat = 9, emphasis: Double = 1.0) {
        self.text = shortcut.displayString
        self.fontSize = fontSize
        self.emphasis = emphasis
    }

    init(text: String, fontSize: CGFloat = 9, emphasis: Double = 1.0) {
        self.text = text
        self.fontSize = fontSize
        self.emphasis = emphasis
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ShortcutHintPillBackground(emphasis: emphasis))
    }
}


/// Applies NSGlassEffectView (macOS 26+) to a window, falling back to NSVisualEffectView
enum WindowGlassEffect {
    private static var glassViewKey: UInt8 = 0
    private static var originalContentViewKey: UInt8 = 0
    private static var tintOverlayKey: UInt8 = 0

    static var isAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    static func apply(to window: NSWindow, tintColor: NSColor? = nil) {
        guard let originalContentView = window.contentView else { return }

        // Check if we already applied glass (avoid re-wrapping)
        if let existingGlass = objc_getAssociatedObject(window, &glassViewKey) as? NSView {
            // Already applied, just update the tint
            updateTint(on: existingGlass, color: tintColor, window: window)
            return
        }

        let bounds = originalContentView.bounds

        // Create the glass/blur view
        let glassView: NSVisualEffectView
        let usingGlassEffectView: Bool

        // Try NSGlassEffectView first (macOS 26 Tahoe+)
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSVisualEffectView.Type {
            usingGlassEffectView = true
            glassView = glassClass.init(frame: bounds)
            glassView.wantsLayer = true
            glassView.layer?.cornerRadius = 0

            // Apply tint color via private API
            if let color = tintColor {
                let selector = NSSelectorFromString("setTintColor:")
                if glassView.responds(to: selector) {
                    glassView.perform(selector, with: color)
                }
            }
        } else {
            usingGlassEffectView = false
            // Fallback to NSVisualEffectView
            glassView = NSVisualEffectView(frame: bounds)
            glassView.blendingMode = .behindWindow
            // Favor a lighter fallback so behind-window glass reads more transparent.
            glassView.material = .underWindowBackground
            glassView.state = .active
            glassView.wantsLayer = true
        }

        glassView.autoresizingMask = [.width, .height]

        if usingGlassEffectView {
            // NSGlassEffectView is a full replacement for the contentView.
            objc_setAssociatedObject(window, &originalContentViewKey, originalContentView, .OBJC_ASSOCIATION_RETAIN)
            window.contentView = glassView

            // Re-add the original SwiftUI hosting view on top of the glass, filling entire area.
            originalContentView.translatesAutoresizingMaskIntoConstraints = false
            originalContentView.wantsLayer = true
            originalContentView.layer?.backgroundColor = NSColor.clear.cgColor
            glassView.addSubview(originalContentView)

            NSLayoutConstraint.activate([
                originalContentView.topAnchor.constraint(equalTo: glassView.topAnchor),
                originalContentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
                originalContentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                originalContentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor)
            ])
        } else {
            // For NSVisualEffectView fallback (macOS 13-15), do NOT replace window.contentView.
            // Replacing contentView can break traffic light rendering with
            // `.fullSizeContentView` + `titlebarAppearsTransparent`.
            glassView.translatesAutoresizingMaskIntoConstraints = false
            originalContentView.addSubview(glassView, positioned: .below, relativeTo: nil)

            NSLayoutConstraint.activate([
                glassView.topAnchor.constraint(equalTo: originalContentView.topAnchor),
                glassView.bottomAnchor.constraint(equalTo: originalContentView.bottomAnchor),
                glassView.leadingAnchor.constraint(equalTo: originalContentView.leadingAnchor),
                glassView.trailingAnchor.constraint(equalTo: originalContentView.trailingAnchor)
            ])
        }

        // Add tint overlay between glass and content (for fallback)
        if let tintColor, !usingGlassEffectView {
            let tintOverlay = NSView(frame: bounds)
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            tintOverlay.wantsLayer = true
            tintOverlay.layer?.backgroundColor = tintColor.cgColor
            glassView.addSubview(tintOverlay)
            NSLayoutConstraint.activate([
                tintOverlay.topAnchor.constraint(equalTo: glassView.topAnchor),
                tintOverlay.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
                tintOverlay.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                tintOverlay.trailingAnchor.constraint(equalTo: glassView.trailingAnchor)
            ])
            objc_setAssociatedObject(window, &tintOverlayKey, tintOverlay, .OBJC_ASSOCIATION_RETAIN)
        }

        // Store reference
        objc_setAssociatedObject(window, &glassViewKey, glassView, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Update the tint color on an existing glass effect
    static func updateTint(to window: NSWindow, color: NSColor?) {
        guard let glassView = objc_getAssociatedObject(window, &glassViewKey) as? NSView else { return }
        updateTint(on: glassView, color: color, window: window)
    }

    private static func updateTint(on glassView: NSView, color: NSColor?, window: NSWindow) {
        // For NSGlassEffectView, use setTintColor:
        if glassView.className == "NSGlassEffectView" {
            let selector = NSSelectorFromString("setTintColor:")
            if glassView.responds(to: selector) {
                glassView.perform(selector, with: color)
            }
        } else {
            // For NSVisualEffectView fallback, update the tint overlay
            if let tintOverlay = objc_getAssociatedObject(window, &tintOverlayKey) as? NSView {
                tintOverlay.layer?.backgroundColor = color?.cgColor
            }
        }
    }

    static func remove(from window: NSWindow) {
        guard let glassView = objc_getAssociatedObject(window, &glassViewKey) as? NSView else {
            return
        }

        if glassView.className == "NSGlassEffectView" {
            if let originalContentView = objc_getAssociatedObject(window, &originalContentViewKey) as? NSView {
                originalContentView.removeFromSuperview()
                originalContentView.translatesAutoresizingMaskIntoConstraints = true
                originalContentView.autoresizingMask = [.width, .height]
                originalContentView.frame = glassView.bounds
                window.contentView = originalContentView
            }
        } else {
            glassView.removeFromSuperview()
        }

        objc_setAssociatedObject(window, &glassViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &originalContentViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &tintOverlayKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// CALayer-backed titlebar background. Uses layer-level opacity (not per-pixel alpha)
/// to match how the terminal's Metal surface composites its background.
struct TitlebarLayerBackground: NSViewRepresentable {
    var backgroundColor: NSColor
    var opacity: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        view.layer?.opacity = Float(opacity)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        nsView.layer?.opacity = Float(opacity)
    }
}

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat

    init(isVisible: Bool = true, persistedWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)) {
        self.isVisible = isVisible
        let sanitized = SessionPersistencePolicy.sanitizedSidebarWidth(Double(persistedWidth))
        self.persistedWidth = CGFloat(sanitized)
    }

    func toggle() {
        isVisible.toggle()
    }
}

enum SidebarResizeInteraction {
    // Keep a generous drag target inside the sidebar itself, but make the
    // terminal-side overlap very small so column-0 text selection still wins.
    static let sidebarSideHitWidth: CGFloat = 6
    // 4 pt matches the 4 pt padding used in GhosttySurfaceScrollView drop zone overlays
    // (dropZoneOverlayFrame). This prevents column-0 text near the leading edge from
    // accidentally triggering the sidebar resize when interacting with leftmost content.
    static let contentSideHitWidth: CGFloat = 4

    static var totalHitWidth: CGFloat {
        sidebarSideHitWidth + contentSideHitWidth
    }
}

// MARK: - File Drop Overlay

enum DragOverlayRoutingPolicy {
    static let bonsplitTabTransferType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    static let sidebarTabReorderType = NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)

    static func hasBonsplitTabTransfer(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(bonsplitTabTransferType)
    }

    static func hasSidebarTabReorder(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(sidebarTabReorderType)
    }

    static func hasFileURL(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(.fileURL)
    }

    static func shouldCaptureFileDropDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hasLocalDraggingSource: Bool
    ) -> Bool {
        // Local file drags (e.g. in-app draggable folder views) are valid drop
        // inputs; rely on explicit non-file drag types below to avoid hijacking
        // Bonsplit/sidebar drags.
        _ = hasLocalDraggingSource
        guard hasFileURL(pasteboardTypes) else { return false }

        // Prefer explicit non-file drag types so stale fileURL entries cannot hijack
        // Bonsplit tab drags or sidebar tab reorder drags.
        if hasBonsplitTabTransfer(pasteboardTypes) { return false }
        if hasSidebarTabReorder(pasteboardTypes) { return false }
        return true
    }

    static func shouldCaptureFileDropDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        shouldCaptureFileDropDestination(
            pasteboardTypes: pasteboardTypes,
            hasLocalDraggingSource: false
        )
    }

    static func shouldCaptureFileDropOverlay(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard shouldCaptureFileDropDestination(pasteboardTypes: pasteboardTypes) else { return false }
        guard isDragMouseEvent(eventType) else { return false }
        return true
    }

    static func shouldCaptureSidebarExternalOverlay(
        hasSidebarDragState: Bool,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        guard hasSidebarDragState else { return false }
        return hasSidebarTabReorder(pasteboardTypes)
    }

    static func shouldCaptureSidebarExternalOverlay(
        draggedTabId: UUID?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        shouldCaptureSidebarExternalOverlay(
            hasSidebarDragState: draggedTabId != nil,
            pasteboardTypes: pasteboardTypes
        )
    }

    static func shouldPassThroughPortalHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard isPortalDragEvent(eventType) else { return false }
        return hasBonsplitTabTransfer(pasteboardTypes) || hasSidebarTabReorder(pasteboardTypes)
    }

    private static func isDragMouseEvent(_ eventType: NSEvent.EventType?) -> Bool {
        eventType == .leftMouseDragged
            || eventType == .rightMouseDragged
            || eventType == .otherMouseDragged
    }

    private static func isPortalDragEvent(_ eventType: NSEvent.EventType?) -> Bool {
        // Restrict portal pass-through to explicit drag-motion events so stale
        // NSPasteboard(name: .drag) types cannot hijack normal pointer input.
        guard let eventType else { return false }
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}

/// Transparent NSView installed on the window's theme frame (above the NSHostingView) to
/// handle file/URL drags from Finder. Nested NSHostingController layers (created by bonsplit's
/// SinglePaneWrapper) prevent AppKit's NSDraggingDestination routing from reaching deeply
/// embedded terminal views. This overlay sits above the entire content view hierarchy and
/// intercepts file drags, forwarding drops to the GhosttyNSView under the cursor.
///
/// Mouse events are forwarded to the views below via a hide-send-unhide pattern so clicks,
/// scrolls, and other interactions pass through normally.
final class FileDropOverlayView: NSView {
    /// Fallback handler when no terminal is found under the drop point.
    var onDrop: (([URL]) -> Bool)?
    private var isForwardingMouseEvent = false
    private weak var forwardedMouseDragTarget: NSView?
    private var forwardedMouseDragButton: ForwardedMouseDragButton?
    /// The WKWebView currently receiving forwarded drag events, so we can
    /// synthesize draggingExited/draggingEntered as the cursor moves.
    private weak var activeDragWebView: WKWebView?
    /// The WKWebView that accepted prepareForDragOperation so conclude can be
    /// delivered to the same browser target after the drop completes.
    private weak var preparedDragWebView: WKWebView?
    private var lastHitTestLogSignature: String?
    private var lastDragRouteLogSignatureByPhase: [String: String] = [:]

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private enum ForwardedMouseDragButton: Equatable {
        case left
        case right
        case other(Int)
    }

    private func dragButton(for event: NSEvent) -> ForwardedMouseDragButton? {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return .other(Int(event.buttonNumber))
        default:
            return nil
        }
    }

    private func shouldTrackForwardedMouseDragStart(for eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }

    private func shouldTrackForwardedMouseDragEnd(for eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    // MARK: Hit-testing — participation is routed by DragOverlayRoutingPolicy so
    // file-drop, bonsplit tab drags, and sidebar tab reorder drags cannot conflict.

    override func hitTest(_ point: NSPoint) -> NSView? {
        let pb = NSPasteboard(name: .drag)
        let eventType = NSApp.currentEvent?.type
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
            pasteboardTypes: pb.types,
            eventType: eventType
        )
#if DEBUG
        logHitTestDecision(
            pasteboardTypes: pb.types,
            eventType: eventType,
            shouldCapture: shouldCapture
        )
#endif
        guard shouldCapture else { return nil }

        return super.hitTest(point)
    }

    // MARK: Mouse forwarding — safety net for the rare case where stale drag pasteboard
    // data causes hitTest to return self when no drag is actually active.
    // We hit-test contentView directly and dispatch to the target rather than using
    // window.sendEvent(), which caches the mouse target and causes infinite recursion.

    private func forwardEvent(_ event: NSEvent) {
        guard !isForwardingMouseEvent else { return }
        guard let window, let contentView = window.contentView else { return }
        let eventButton = dragButton(for: event)

        isForwardingMouseEvent = true
        isHidden = true
        defer {
            isHidden = false
            isForwardingMouseEvent = false
        }

        let target: NSView?
        if let eventButton,
           forwardedMouseDragButton == eventButton,
           let activeTarget = forwardedMouseDragTarget,
           activeTarget.window != nil {
            // Preserve normal AppKit mouse-delivery semantics: once a drag starts,
            // keep routing dragged/up events to the original mouseDown target.
            target = activeTarget
        } else {
            let point = contentView.convert(event.locationInWindow, from: nil)
            target = contentView.hitTest(point)
        }

        guard let target, target !== self else {
            if shouldTrackForwardedMouseDragEnd(for: event.type),
               let eventButton,
               forwardedMouseDragButton == eventButton {
                forwardedMouseDragTarget = nil
                forwardedMouseDragButton = nil
            }
            return
        }

        if shouldTrackForwardedMouseDragStart(for: event.type), let eventButton {
            forwardedMouseDragTarget = target
            forwardedMouseDragButton = eventButton
        }

        switch event.type {
        case .leftMouseDown: target.mouseDown(with: event)
        case .leftMouseUp: target.mouseUp(with: event)
        case .leftMouseDragged: target.mouseDragged(with: event)
        case .rightMouseDown: target.rightMouseDown(with: event)
        case .rightMouseUp: target.rightMouseUp(with: event)
        case .rightMouseDragged: target.rightMouseDragged(with: event)
        case .otherMouseDown: target.otherMouseDown(with: event)
        case .otherMouseUp: target.otherMouseUp(with: event)
        case .otherMouseDragged: target.otherMouseDragged(with: event)
        case .scrollWheel: target.scrollWheel(with: event)
        default: break
        }

        if shouldTrackForwardedMouseDragEnd(for: event.type),
           let eventButton,
           forwardedMouseDragButton == eventButton {
            forwardedMouseDragTarget = nil
            forwardedMouseDragButton = nil
        }
    }

    override func mouseDown(with event: NSEvent) { forwardEvent(event) }
    override func mouseUp(with event: NSEvent) { forwardEvent(event) }
    override func mouseDragged(with event: NSEvent) { forwardEvent(event) }
    override func rightMouseDown(with event: NSEvent) { forwardEvent(event) }
    override func rightMouseUp(with event: NSEvent) { forwardEvent(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardEvent(event) }
    override func otherMouseDown(with event: NSEvent) { forwardEvent(event) }
    override func otherMouseUp(with event: NSEvent) { forwardEvent(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardEvent(event) }
    override func scrollWheel(with event: NSEvent) { forwardEvent(event) }

    // MARK: NSDraggingDestination – accept file drops over terminal and browser views.
    //
    // AppKit sends draggingEntered once when the drag enters this overlay, then
    // draggingUpdated as the cursor moves within it. We track which WKWebView (if
    // any) is under the cursor and synthesize enter/exit calls so the browser's
    // HTML5 drag events (dragenter, dragleave, drop) fire correctly.

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return updateDragTarget(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return updateDragTarget(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        preparedDragWebView = nil
        if let prev = activeDragWebView {
            prev.draggingExited(sender)
            activeDragWebView = nil
        }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let hasLocalDraggingSource = sender.draggingSource != nil
        let types = sender.draggingPasteboard.types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
        let webView = shouldCapture ? (activeDragWebView ?? webViewUnderPoint(sender.draggingLocation)) : nil
        let terminal = terminalUnderPoint(sender.draggingLocation)
        let hasTerminalTarget = terminal != nil
#if DEBUG
        logDragRouteDecision(
            phase: "prepare",
            pasteboardTypes: types,
            shouldCapture: shouldCapture,
            hasLocalDraggingSource: hasLocalDraggingSource,
            hasTerminalTarget: hasTerminalTarget
        )
#endif
        guard shouldCapture else {
            preparedDragWebView = nil
            return false
        }
        if let webView {
            preparedDragWebView = webView
            return webView.prepareForDragOperation(sender)
        }
        preparedDragWebView = nil
        return hasTerminalTarget
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let hasLocalDraggingSource = sender.draggingSource != nil
        let types = sender.draggingPasteboard.types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
        let webView = shouldCapture
            ? (preparedDragWebView ?? activeDragWebView ?? webViewUnderPoint(sender.draggingLocation))
            : nil
        let terminal = terminalUnderPoint(sender.draggingLocation)
        let hasTerminalTarget = terminal != nil
#if DEBUG
        logDragRouteDecision(
            phase: "perform",
            pasteboardTypes: types,
            shouldCapture: shouldCapture,
            hasLocalDraggingSource: hasLocalDraggingSource,
            hasTerminalTarget: hasTerminalTarget
        )
#endif
        guard shouldCapture else {
            preparedDragWebView = nil
            activeDragWebView = nil
            return false
        }
        if let webView {
            preparedDragWebView = webView
            return webView.performDragOperation(sender)
        }
        preparedDragWebView = nil
        activeDragWebView = nil
        guard let terminal else { return false }
        return terminal.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        defer {
            preparedDragWebView = nil
            activeDragWebView = nil
        }
        guard let sender else { return }
        let webView = preparedDragWebView ?? activeDragWebView ?? webViewUnderPoint(sender.draggingLocation)
        webView?.concludeDragOperation(sender)
    }

    private func updateDragTarget(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let loc = sender.draggingLocation
        let hasLocalDraggingSource = sender.draggingSource != nil
        let types = sender.draggingPasteboard.types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
        let webView = shouldCapture ? webViewUnderPoint(loc) : nil

        if let prev = activeDragWebView, prev !== webView {
            prev.draggingExited(sender)
            activeDragWebView = nil
        }

        if let webView {
            if activeDragWebView !== webView {
                activeDragWebView = webView
                return webView.draggingEntered(sender)
            }
            return webView.draggingUpdated(sender)
        }

        let hasTerminalTarget = terminalUnderPoint(loc) != nil
#if DEBUG
        logDragRouteDecision(
            phase: phase,
            pasteboardTypes: types,
            shouldCapture: shouldCapture,
            hasLocalDraggingSource: hasLocalDraggingSource,
            hasTerminalTarget: hasTerminalTarget
        )
#endif
        guard shouldCapture, hasTerminalTarget else { return [] }
        return .copy
    }

    private func debugPasteboardTypes(_ types: [NSPasteboard.PasteboardType]?) -> String {
        guard let types, !types.isEmpty else { return "-" }
        return types.map(\.rawValue).joined(separator: ",")
    }

    /// Hit-tests the window to find a WKWebView (browser panel) under the cursor.
    func webViewUnderPoint(_ windowPoint: NSPoint) -> WKWebView? {
        if let window,
           let portalWebView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window) {
            return portalWebView
        }

        guard let window, let contentView = window.contentView else { return nil }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(windowPoint, from: nil)
        let hitView = contentView.hitTest(point)

        var current: NSView? = hitView
        while let view = current {
            if let webView = view as? WKWebView { return webView }
            current = view.superview
        }
        return nil
    }

    private func debugTopHitViewForCurrentEvent() -> String {
        guard let window,
              let currentEvent = NSApp.currentEvent,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return "-" }

        let pointInTheme = themeFrame.convert(currentEvent.locationInWindow, from: nil)
        // Don't toggle isHidden here — it triggers setNeedsDisplay which can
        // exceed AppKit's display-pass limit during cursor-update display cycles.
        guard let hit = themeFrame.hitTest(pointInTheme) else { return "nil" }
        var chain: [String] = []
        var current: NSView? = hit
        var depth = 0
        while let view = current, depth < 6 {
            chain.append(debugHitViewDescriptor(view))
            current = view.superview
            depth += 1
        }
        return chain.joined(separator: "->")
    }

    private func debugHitViewDescriptor(_ view: NSView) -> String {
        let className = String(describing: type(of: view))
        let ptr = String(describing: Unmanaged.passUnretained(view).toOpaque())
        let dragTypes = debugRegisteredDragTypes(view)
        return "\(className)@\(ptr){dragTypes=\(dragTypes)}"
    }

    private func debugRegisteredDragTypes(_ view: NSView) -> String {
        let types = view.registeredDraggedTypes
        guard !types.isEmpty else { return "-" }

        let interestingTypes = types.filter { type in
            let raw = type.rawValue
            return raw == NSPasteboard.PasteboardType.fileURL.rawValue
                || raw == DragOverlayRoutingPolicy.bonsplitTabTransferType.rawValue
                || raw == DragOverlayRoutingPolicy.sidebarTabReorderType.rawValue
                || raw.contains("public.text")
                || raw.contains("public.url")
                || raw.contains("public.data")
        }
        let selected = interestingTypes.isEmpty ? Array(types.prefix(3)) : interestingTypes
        let rendered = selected.map(\.rawValue).joined(separator: ",")
        if selected.count < types.count {
            return "\(rendered),+\(types.count - selected.count)"
        }
        return rendered
    }

    private func hasRelevantDragTypes(_ types: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let types else { return false }
        return types.contains(.fileURL)
            || types.contains(DragOverlayRoutingPolicy.bonsplitTabTransferType)
            || types.contains(DragOverlayRoutingPolicy.sidebarTabReorderType)
    }

    private func debugEventName(_ eventType: NSEvent.EventType?) -> String {
        guard let eventType else { return "none" }
        switch eventType {
        case .cursorUpdate: return "cursorUpdate"
        case .appKitDefined: return "appKitDefined"
        case .systemDefined: return "systemDefined"
        case .applicationDefined: return "applicationDefined"
        case .periodic: return "periodic"
        case .mouseMoved: return "mouseMoved"
        case .mouseEntered: return "mouseEntered"
        case .mouseExited: return "mouseExited"
        case .flagsChanged: return "flagsChanged"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        case .scrollWheel: return "scrollWheel"
        default: return "other(\(eventType.rawValue))"
        }
    }

#if DEBUG
    private func logHitTestDecision(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?,
        shouldCapture: Bool
    ) {
        let isDragEvent = eventType == .leftMouseDragged
            || eventType == .rightMouseDragged
            || eventType == .otherMouseDragged
        guard shouldCapture || isDragEvent || hasRelevantDragTypes(pasteboardTypes) else { return }

        let signature = "\(shouldCapture ? 1 : 0)|\(debugEventName(eventType))|\(debugPasteboardTypes(pasteboardTypes))"
        guard lastHitTestLogSignature != signature else { return }
        lastHitTestLogSignature = signature
        dlog(
            "overlay.fileDrop.hitTest capture=\(shouldCapture ? 1 : 0) " +
            "event=\(debugEventName(eventType)) " +
            "topHit=\(debugTopHitViewForCurrentEvent()) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }

    private func logDragRouteDecision(
        phase: String,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        shouldCapture: Bool,
        hasLocalDraggingSource: Bool,
        hasTerminalTarget: Bool
    ) {
        guard shouldCapture || hasRelevantDragTypes(pasteboardTypes) else { return }
        let signature = [
            shouldCapture ? "1" : "0",
            hasLocalDraggingSource ? "1" : "0",
            hasTerminalTarget ? "1" : "0",
            debugPasteboardTypes(pasteboardTypes)
        ].joined(separator: "|")
        guard lastDragRouteLogSignatureByPhase[phase] != signature else { return }
        lastDragRouteLogSignatureByPhase[phase] = signature
        dlog(
            "overlay.fileDrop.\(phase) capture=\(shouldCapture ? 1 : 0) " +
            "localSource=\(hasLocalDraggingSource ? 1 : 0) " +
            "hasTerminal=\(hasTerminalTarget ? 1 : 0) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }
#endif
    /// Hit-tests the window to find the GhosttyNSView under the cursor.
    func terminalUnderPoint(_ windowPoint: NSPoint) -> GhosttyNSView? {
        if let window,
           let portalTerminal = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window) {
            return portalTerminal
        }

        guard let window, let contentView = window.contentView else { return nil }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(windowPoint, from: nil)
        let hitView = contentView.hitTest(point)

        var current: NSView? = hitView
        while let view = current {
            if let terminal = view as? GhosttyNSView { return terminal }
            current = view.superview
        }
        return nil
    }
}

var fileDropOverlayKey: UInt8 = 0
private var commandPaletteWindowOverlayKey: UInt8 = 0
private var tmuxWorkspacePaneWindowOverlayKey: UInt8 = 0
let commandPaletteOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.commandPalette.overlay.container")
let tmuxWorkspacePaneOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.tmuxWorkspacePane.overlay.container")

enum CommandPaletteOverlayPromotionPolicy {
    static func shouldPromote(previouslyVisible: Bool, isVisible: Bool) -> Bool {
        isVisible && !previouslyVisible
    }
}

@MainActor
private final class CommandPaletteOverlayContainerView: NSView {
    var capturesMouseEvents = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesMouseEvents else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
private final class PassthroughWindowOverlayContainerView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

#if DEBUG
private func debugCommandPaletteWindowSummary(_ window: NSWindow?) -> String {
    guard let window else { return "nil" }
    let ident = window.identifier?.rawValue ?? "nil"
    return "num=\(window.windowNumber) ident=\(ident) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
}

private func debugCommandPaletteNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

private func debugCommandPaletteModifierFlagsSummary(_ flags: NSEvent.ModifierFlags) -> String {
    let normalized = debugCommandPaletteNormalizedModifierFlags(flags)
    var parts: [String] = []
    if normalized.contains(.command) { parts.append("cmd") }
    if normalized.contains(.shift) { parts.append("shift") }
    if normalized.contains(.option) { parts.append("opt") }
    if normalized.contains(.control) { parts.append("ctrl") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

private func debugCommandPaletteKeyEventSummary(_ event: NSEvent) -> String {
    let chars = event.characters.map(String.init(reflecting:)) ?? "nil"
    let charsIgnoring = event.charactersIgnoringModifiers.map(String.init(reflecting:)) ?? "nil"
    return
        "type=\(event.type) keyCode=\(event.keyCode) flags=\(debugCommandPaletteModifierFlagsSummary(event.modifierFlags)) " +
        "chars=\(chars) charsIgnoring=\(charsIgnoring)"
}

private func debugCommandPaletteTextPreview(_ text: String, limit: Int = 120) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    if escaped.count <= limit {
        return escaped
    }
    let prefix = escaped.prefix(limit)
    return "\(prefix)..."
}

private func debugCommandPaletteResponderSummary(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }

    let typeName = String(describing: type(of: responder))
    if let textView = responder as? NSTextView {
        let selection = textView.selectedRange()
        return "\(typeName){fieldEditor=\(textView.isFieldEditor ? 1 : 0) editable=\(textView.isEditable ? 1 : 0) selectable=\(textView.isSelectable ? 1 : 0) hidden=\(textView.isHiddenOrHasHiddenAncestor ? 1 : 0) len=\((textView.string as NSString).length) sel=\(selection.location):\(selection.length)}"
    }

    if let textField = responder as? NSTextField {
        return "\(typeName){editable=\(textField.isEditable ? 1 : 0) enabled=\(textField.isEnabled ? 1 : 0) hidden=\(textField.isHiddenOrHasHiddenAncestor ? 1 : 0) len=\((textField.stringValue as NSString).length)}"
    }

    if let view = responder as? NSView {
        return "\(typeName){hidden=\(view.isHiddenOrHasHiddenAncestor ? 1 : 0)}"
    }

    return typeName
}
#endif

@MainActor
private final class WindowCommandPaletteOverlayController: NSObject {
    private weak var window: NSWindow?
    private let containerView = CommandPaletteOverlayContainerView(frame: .zero)
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedThemeFrame: NSView?
    private var focusLockTimer: DispatchSourceTimer?
    private var scheduledFocusWorkItem: DispatchWorkItem?
    private var isPaletteVisible = false
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    private var windowDidResignKeyObserver: NSObjectProtocol?

    init(window: NSWindow) {
        self.window = window
        super.init()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.isHidden = true
        containerView.alphaValue = 0
        containerView.capturesMouseEvents = false
        containerView.identifier = commandPaletteOverlayContainerIdentifier
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        _ = ensureInstalled()
        installWindowKeyObservers()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return false }

        if containerView.superview !== themeFrame {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            containerView.removeFromSuperview()
            themeFrame.addSubview(containerView, positioned: .above, relativeTo: nil)
            installConstraints = [
                containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedThemeFrame = themeFrame
        }

        return true
    }

    private func promoteOverlayAboveSiblingsIfNeeded() {
        guard let themeFrame = installedThemeFrame,
              containerView.superview === themeFrame else { return }
        themeFrame.addSubview(containerView, positioned: .above, relativeTo: nil)
    }

    private func isPaletteResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if let view = responder as? NSView, view.isDescendant(of: containerView) {
            return true
        }

        if let textView = responder as? NSTextView {
            if let delegateView = textView.delegate as? NSView,
               delegateView.isDescendant(of: containerView) {
                return true
            }
        }

        return false
    }

    private func isPaletteFieldEditor(_ textView: NSTextView) -> Bool {
        guard textView.isFieldEditor else { return false }

        if let delegateView = textView.delegate as? NSView,
           delegateView.isDescendant(of: containerView) {
            return true
        }

        // SwiftUI text fields can keep a field editor delegate that isn't an NSView.
        // Fall back to validating editor ownership from the mounted palette text field.
        if let textField = firstEditableTextField(in: hostingView),
           textField.currentEditor() === textView {
            return true
        }

        return false
    }

    private func isPaletteMultilineTextView(_ textView: NSTextView) -> Bool {
        guard !textView.isFieldEditor,
              textView.isEditable,
              textView.isSelectable,
              !textView.isHiddenOrHasHiddenAncestor,
              textView.isDescendant(of: containerView) else { return false }
        return true
    }

    private func isPaletteTextInputFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if let textView = responder as? NSTextView {
            return isPaletteFieldEditor(textView) || isPaletteMultilineTextView(textView)
        }

        if let textField = responder as? NSTextField {
            return textField.isDescendant(of: containerView)
        }

        return false
    }

    private func firstEditableTextInput(in view: NSView) -> NSResponder? {
        if let textField = view as? NSTextField,
           textField.isEditable,
           textField.isEnabled,
           !textField.isHiddenOrHasHiddenAncestor {
            return textField
        }

        if let textView = view as? NSTextView,
           !textView.isFieldEditor,
           textView.isEditable,
           textView.isSelectable,
           !textView.isHiddenOrHasHiddenAncestor {
            return textView
        }

        for subview in view.subviews {
            if let match = firstEditableTextInput(in: subview) {
                return match
            }
        }
        return nil
    }

    private func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField,
           textField.isEditable,
           textField.isEnabled,
           !textField.isHiddenOrHasHiddenAncestor {
            return textField
        }

        for subview in view.subviews {
            if let match = firstEditableTextField(in: subview) {
                return match
            }
        }
        return nil
    }

    private func focusPaletteTextInput(in window: NSWindow) -> Bool {
        guard let input = firstEditableTextInput(in: hostingView) else {
#if DEBUG
            dlog(
                "palette.focus.direct missingInput window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            return false
        }
#if DEBUG
        dlog(
            "palette.focus.direct attempt window={\(debugCommandPaletteWindowSummary(window))} " +
            "input=\(debugCommandPaletteResponderSummary(input)) " +
            "frBefore=\(debugCommandPaletteResponderSummary(window.firstResponder))"
        )
#endif
        guard window.makeFirstResponder(input) else {
#if DEBUG
            dlog(
                "palette.focus.direct failedMakeFirstResponder window={\(debugCommandPaletteWindowSummary(window))} " +
                "input=\(debugCommandPaletteResponderSummary(input)) " +
                "frAfter=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            return false
        }

        if let textView = input as? NSTextView, !textView.isFieldEditor {
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
        } else {
            normalizeSelectionAfterProgrammaticFocus()
        }

        let didSettle = isPaletteTextInputFirstResponder(window.firstResponder)
#if DEBUG
        dlog(
            "palette.focus.direct settled window={\(debugCommandPaletteWindowSummary(window))} " +
            "didSettle=\(didSettle ? 1 : 0) frAfter=\(debugCommandPaletteResponderSummary(window.firstResponder))"
        )
#endif
        return didSettle
    }

    private func scheduleFocusIntoPalette(retries: Int = 4) {
#if DEBUG
        if let window {
            dlog(
                "palette.focus.schedule retries=\(retries) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
        } else {
            dlog("palette.focus.schedule retries=\(retries) window=nil")
        }
#endif
        scheduledFocusWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.scheduledFocusWorkItem = nil
            self?.focusIntoPalette(retries: retries)
        }
        scheduledFocusWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func focusIntoPalette(retries: Int) {
        guard let window else { return }
#if DEBUG
        dlog(
            "palette.focus.retry start retries=\(retries) " +
            "window={\(debugCommandPaletteWindowSummary(window))} " +
            "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
        )
#endif
        if isPaletteTextInputFirstResponder(window.firstResponder) {
#if DEBUG
            dlog(
                "palette.focus.retry alreadyFocused window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            return
        }

        if focusPaletteTextInput(in: window) {
#if DEBUG
            dlog(
                "palette.focus.retry directSuccess retries=\(retries) " +
                "window={\(debugCommandPaletteWindowSummary(window))}"
            )
#endif
            return
        }

        let containerFocused = window.makeFirstResponder(containerView)
#if DEBUG
        dlog(
            "palette.focus.retry containerResult retries=\(retries) " +
            "window={\(debugCommandPaletteWindowSummary(window))} " +
            "didFocusContainer=\(containerFocused ? 1 : 0) " +
            "frAfterContainer=\(debugCommandPaletteResponderSummary(window.firstResponder))"
        )
#endif
        if containerFocused {
            if focusPaletteTextInput(in: window) {
#if DEBUG
                dlog(
                    "palette.focus.retry containerAssistedSuccess retries=\(retries) " +
                    "window={\(debugCommandPaletteWindowSummary(window))}"
                )
#endif
                return
            }
        }

        guard retries > 0 else {
#if DEBUG
            dlog(
                "palette.focus.retry exhausted window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            return
        }
#if DEBUG
        dlog(
            "palette.focus.retry reschedule nextRetries=\(retries - 1) " +
            "window={\(debugCommandPaletteWindowSummary(window))}"
        )
#endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.focusIntoPalette(retries: retries - 1)
        }
    }

    private func installWindowKeyObservers() {
        guard let window else { return }
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFocusLockForWindowState()
            }
        }
        windowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFocusLockForWindowState()
            }
        }
    }

    private func updateFocusLockForWindowState() {
        guard let window else {
            stopFocusLockTimer()
            return
        }
        guard isPaletteVisible else {
#if DEBUG
            dlog(
                "palette.focus.lock inactive visible=0 window={\(debugCommandPaletteWindowSummary(window))}"
            )
#endif
            stopFocusLockTimer()
            return
        }

        guard window.isKeyWindow else {
#if DEBUG
            dlog(
                "palette.focus.lock keyWindowMissing window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            stopFocusLockTimer()
            if isPaletteResponder(window.firstResponder) {
                _ = window.makeFirstResponder(nil)
            }
            return
        }

        startFocusLockTimer()
        if !isPaletteTextInputFirstResponder(window.firstResponder) {
#if DEBUG
            dlog(
                "palette.focus.lock requestRestore window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            scheduleFocusIntoPalette(retries: 8)
        }
    }

    private func startFocusLockTimer() {
        guard focusLockTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(12))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                self.stopFocusLockTimer()
                return
            }
            if self.isPaletteTextInputFirstResponder(window.firstResponder) {
                return
            }
            self.focusIntoPalette(retries: 1)
        }
        focusLockTimer = timer
        timer.resume()
    }

    private func stopFocusLockTimer() {
        focusLockTimer?.cancel()
        focusLockTimer = nil
        scheduledFocusWorkItem?.cancel()
        scheduledFocusWorkItem = nil
    }

    private func normalizeSelectionAfterProgrammaticFocus() {
        guard let window,
              let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else { return }

        let text = editor.string
        let length = (text as NSString).length
        let selection = editor.selectedRange()
        guard length > 0 else { return }
        guard selection.location == 0, selection.length == length else { return }

        // Keep commands-mode prefix semantics stable after focus re-assertions:
        // if AppKit selected the entire query (e.g. ">foo"), restore caret-at-end
        // so the next keystroke appends instead of replacing and switching modes.
        guard text.hasPrefix(">") else { return }
        editor.setSelectedRange(NSRange(location: length, length: 0))
    }

    func update(rootView: AnyView, isVisible: Bool) {
        guard ensureInstalled() else { return }
        let shouldPromote = CommandPaletteOverlayPromotionPolicy.shouldPromote(
            previouslyVisible: isPaletteVisible,
            isVisible: isVisible
        )
#if DEBUG
        if let window {
            dlog(
                "palette.overlay.update visible=\(isVisible ? 1 : 0) promote=\(shouldPromote ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
        } else {
            dlog("palette.overlay.update visible=\(isVisible ? 1 : 0) promote=\(shouldPromote ? 1 : 0) window=nil")
        }
#endif
        isPaletteVisible = isVisible
        if isVisible {
            hostingView.rootView = rootView
            containerView.capturesMouseEvents = true
            containerView.isHidden = false
            containerView.alphaValue = 1
            if shouldPromote {
                promoteOverlayAboveSiblingsIfNeeded()
            }
            updateFocusLockForWindowState()
        } else {
            stopFocusLockTimer()
            if let window, isPaletteResponder(window.firstResponder) {
                _ = window.makeFirstResponder(nil)
            }
            hostingView.rootView = AnyView(EmptyView())
            containerView.capturesMouseEvents = false
            containerView.alphaValue = 0
            containerView.isHidden = true
        }
    }

    func underlyingResponder(atWindowPoint windowPoint: NSPoint) -> NSResponder? {
        guard let window,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else {
            return nil
        }

        let previousCapturesMouseEvents = containerView.capturesMouseEvents
        containerView.capturesMouseEvents = false
        defer {
            containerView.capturesMouseEvents = previousCapturesMouseEvents
        }

        let pointInTheme = themeFrame.convert(windowPoint, from: nil)
        return themeFrame.hitTest(pointInTheme)
    }
}

@MainActor
private func commandPaletteWindowOverlayController(for window: NSWindow) -> WindowCommandPaletteOverlayController {
    if let existing = objc_getAssociatedObject(window, &commandPaletteWindowOverlayKey) as? WindowCommandPaletteOverlayController {
        return existing
    }
    let controller = WindowCommandPaletteOverlayController(window: window)
    objc_setAssociatedObject(window, &commandPaletteWindowOverlayKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return controller
}

@MainActor
private final class WindowTmuxWorkspacePaneOverlayController: NSObject {
    private weak var window: NSWindow?
    private let containerView = PassthroughWindowOverlayContainerView(frame: .zero)
    private let model = TmuxWorkspacePaneOverlayModel()
    private let hostingView: NSHostingView<TmuxWorkspacePaneOverlayView>
    private var installConstraints: [NSLayoutConstraint] = []

    init(window: NSWindow) {
        self.window = window
        self.hostingView = NSHostingView(
            rootView: TmuxWorkspacePaneOverlayView(
                unreadRects: [],
                flashRect: nil,
                flashStartedAt: nil,
                flashReason: nil
            )
        )
        super.init()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.isHidden = true
        containerView.alphaValue = 0
        containerView.identifier = tmuxWorkspacePaneOverlayContainerIdentifier
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        _ = ensureInstalled()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return false }

        if containerView.superview !== themeFrame {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            containerView.removeFromSuperview()
            themeFrame.addSubview(containerView, positioned: .above, relativeTo: contentView)
            installConstraints = [
                containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
        }

        return true
    }

    func update(state: TmuxWorkspacePaneOverlayRenderState?) {
        guard ensureInstalled() else { return }
        if let state {
            model.apply(state)
            hostingView.rootView = TmuxWorkspacePaneOverlayView(
                unreadRects: model.unreadRects,
                flashRect: model.flashRect,
                flashStartedAt: model.flashStartedAt,
                flashReason: model.flashReason
            )
            containerView.alphaValue = 1
            containerView.isHidden = false
        } else {
            model.clear()
            hostingView.rootView = TmuxWorkspacePaneOverlayView(
                unreadRects: [],
                flashRect: nil,
                flashStartedAt: nil,
                flashReason: nil
            )
            containerView.alphaValue = 0
            containerView.isHidden = true
        }
    }
}

@MainActor
private func tmuxWorkspacePaneWindowOverlayController(for window: NSWindow) -> WindowTmuxWorkspacePaneOverlayController {
    if let existing = objc_getAssociatedObject(window, &tmuxWorkspacePaneWindowOverlayKey) as? WindowTmuxWorkspacePaneOverlayController {
        return existing
    }
    let controller = WindowTmuxWorkspacePaneOverlayController(window: window)
    objc_setAssociatedObject(window, &tmuxWorkspacePaneWindowOverlayKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return controller
}

private func commandPaletteOwningWebView(for responder: NSResponder?) -> WKWebView? {
    guard let responder else { return nil }

    if let webView = responder as? WKWebView {
        return webView
    }

    if let view = responder as? NSView {
        var current: NSView? = view
        while let candidate = current {
            if let webView = candidate as? WKWebView {
                return webView
            }
            current = candidate.superview
        }
    }

    if let textView = responder as? NSTextView,
       let delegateView = textView.delegate as? NSView,
       let webView = commandPaletteOwningWebView(for: delegateView) {
        return webView
    }

    var currentResponder = responder.nextResponder
    while let next = currentResponder {
        if let webView = commandPaletteOwningWebView(for: next) {
            return webView
        }
        currentResponder = next.nextResponder
    }

    return nil
}

enum WorkspaceMountPolicy {
    // Keep only the selected workspace mounted to minimize layer-tree traversal.
    static let maxMountedWorkspaces = 1
    // During workspace cycling, keep only a minimal handoff pair (selected + retiring).
    static let maxMountedWorkspacesDuringCycle = 2

    static func nextMountedWorkspaceIds(
        current: [UUID],
        selected: UUID?,
        pinnedIds: Set<UUID>,
        orderedTabIds: [UUID],
        isCycleHot: Bool,
        maxMounted: Int
    ) -> [UUID] {
        let existing = Set(orderedTabIds)
        let clampedMax = max(1, maxMounted)
        var ordered = current.filter { existing.contains($0) }

        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }

        if isCycleHot, let selected {
            let warmIds = cycleWarmIds(selected: selected, orderedTabIds: orderedTabIds)
            for id in warmIds.reversed() {
                ordered.removeAll { $0 == id }
                ordered.insert(id, at: 0)
            }
        }

        if isCycleHot,
           pinnedIds.isEmpty,
           let selected {
            ordered.removeAll { $0 != selected }
        }

        // Ensure pinned ids (retiring handoff workspaces) are always retained at highest priority.
        // This runs after warming to prevent neighbor warming from evicting the retiring workspace.
        let prioritizedPinnedIds = pinnedIds
            .filter { existing.contains($0) && $0 != selected }
            .sorted { lhs, rhs in
                let lhsIndex = orderedTabIds.firstIndex(of: lhs) ?? .max
                let rhsIndex = orderedTabIds.firstIndex(of: rhs) ?? .max
                return lhsIndex < rhsIndex
            }
        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }
        var pinnedInsertionIndex = (selected != nil) ? 1 : 0
        for pinnedId in prioritizedPinnedIds {
            ordered.removeAll { $0 == pinnedId }
            let insertionIndex = min(pinnedInsertionIndex, ordered.count)
            ordered.insert(pinnedId, at: insertionIndex)
            pinnedInsertionIndex += 1
        }

        if ordered.count > clampedMax {
            ordered.removeSubrange(clampedMax...)
        }

        return ordered
    }

    private static func cycleWarmIds(selected: UUID, orderedTabIds: [UUID]) -> [UUID] {
        guard orderedTabIds.contains(selected) else { return [selected] }
        // Keep warming focused to the selected workspace. Retiring/target workspaces are
        // pinned by handoff logic, so warming adjacent neighbors here just adds layout work.
        return [selected]
    }
}

struct MountedWorkspacePresentation: Equatable {
    let isRenderedVisible: Bool
    let isPanelVisible: Bool
    let renderOpacity: Double
}

enum MountedWorkspacePresentationPolicy {
    static func resolve(
        isSelectedWorkspace: Bool,
        isRetiringWorkspace: Bool,
        shouldPrimeInBackground: Bool
    ) -> MountedWorkspacePresentation {
        let isRenderedVisible = isSelectedWorkspace || isRetiringWorkspace
        let renderOpacity: Double = {
            if isRenderedVisible {
                return 1
            }
            if shouldPrimeInBackground {
                // Keep the workspace mounted long enough to warm the terminal surface, but do
                // not mark it panel-visible. Visible portal entries intentionally survive
                // transient anchor loss during bonsplit drag/reparent churn.
                return 0.001
            }
            return 0
        }()

        return MountedWorkspacePresentation(
            isRenderedVisible: isRenderedVisible,
            isPanelVisible: isRenderedVisible,
            renderOpacity: renderOpacity
        )
    }
}

/// Installs a FileDropOverlayView on the window's theme frame for Finder file drag support.
private func findFileDropOverlayView(in root: NSView?) -> FileDropOverlayView? {
    guard let root else { return nil }
    if let overlay = root as? FileDropOverlayView {
        return overlay
    }
    for subview in root.subviews {
        if let overlay = findFileDropOverlayView(in: subview) {
            return overlay
        }
    }
    return nil
}

private func configureFileDropOverlay(_ overlay: FileDropOverlayView, tabManager: TabManager) {
    overlay.onDrop = { [weak tabManager] urls in
        MainActor.assumeIsolated {
            guard let tabManager, let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return false }
            return terminal.hostedView.handleDroppedURLs(urls)
        }
    }
}

private func attachFileDropOverlay(_ overlay: FileDropOverlayView, to contentView: NSView, in themeFrame: NSView) {
    overlay.translatesAutoresizingMaskIntoConstraints = false
    themeFrame.addSubview(overlay, positioned: .above, relativeTo: contentView)
    NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
        overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
    ])
}

@discardableResult
func installFileDropOverlay(on window: NSWindow, tabManager: TabManager) -> Bool {
    guard let contentView = window.contentView,
          let themeFrame = contentView.superview else { return false }

    let existingOverlay =
        (objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView)
        ?? findFileDropOverlayView(in: themeFrame)

    if let existingOverlay {
        configureFileDropOverlay(existingOverlay, tabManager: tabManager)
        objc_setAssociatedObject(window, &fileDropOverlayKey, existingOverlay, .OBJC_ASSOCIATION_RETAIN)
        guard existingOverlay.superview !== themeFrame else { return true }
        existingOverlay.removeFromSuperview()
        attachFileDropOverlay(existingOverlay, to: contentView, in: themeFrame)
        return true
    }

    let overlay = FileDropOverlayView(frame: contentView.frame)
    configureFileDropOverlay(overlay, tabManager: tabManager)
    // Publish the overlay before mutating the view tree so any re-entrant lookup resolves
    // the in-flight view instead of installing a second overlay during layout.
    objc_setAssociatedObject(window, &fileDropOverlayKey, overlay, .OBJC_ASSOCIATION_RETAIN)
    attachFileDropOverlay(overlay, to: contentView, in: themeFrame)
    return true
}

private func installFileDropOverlayWhenReady(
    on window: NSWindow,
    tabManager: TabManager,
    remainingAttempts: Int = 16
) {
    guard !installFileDropOverlay(on: window, tabManager: tabManager),
          remainingAttempts > 0 else { return }

    // Defer retrying until the next main-loop turn so we don't mutate the
    // NSThemeFrame hierarchy while SwiftUI/AppKit is still attaching views.
    DispatchQueue.main.async { [weak window, weak tabManager] in
        guard let window, let tabManager else { return }
        installFileDropOverlayWhenReady(
            on: window,
            tabManager: tabManager,
            remainingAttempts: remainingAttempts - 1
        )
    }
}

@MainActor
private final class SelectedWorkspaceDirectoryObserver: ObservableObject {
    @Published private(set) var directoryChangeGeneration: UInt64 = 0
    private weak var tabManager: TabManager?
    private var cancellable: AnyCancellable?

    func wire(tabManager: TabManager) {
        guard self.tabManager !== tabManager || cancellable == nil else { return }
        self.tabManager = tabManager
        cancellable = tabManager.$selectedTabId
            .map { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0?.id == $1?.id })
            .map { workspace -> AnyPublisher<(UUID?, String?), Never> in
                guard let workspace else {
                    return Just<(UUID?, String?)>((nil, nil)).eraseToAnyPublisher()
                }
                return workspace.$currentDirectory
                    .map { (Optional(workspace.id), Optional($0)) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates { previous, next in
                previous.0 == next.0 && previous.1 == next.1
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.directoryChangeGeneration &+= 1
            }
    }
}

struct ContentView: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let windowId: UUID
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var sidebarState: SidebarState
    @EnvironmentObject var sidebarSelectionState: SidebarSelectionState
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore
    @EnvironmentObject var fileExplorerState: FileExplorerState
    @State private var sidebarWidth: CGFloat = 200
    @State private var hoveredResizerHandles: Set<SidebarResizerHandle> = []
    @State private var isResizerDragging = false
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var selectedTabIds: Set<UUID> = []
    @State private var mountedWorkspaceIds: [UUID] = []
    @State private var lastSidebarSelectionIndex: Int? = nil
    @State private var titlebarText: String = ""
    @State private var isFullScreen: Bool = false
    @State private var observedWindow: NSWindow?
    @StateObject private var fullscreenControlsViewModel = TitlebarControlsViewModel()
    @StateObject private var fileExplorerStore = FileExplorerStore()
    @StateObject private var sessionIndexStore = SessionIndexStore()
    @StateObject private var selectedWorkspaceDirectoryObserver = SelectedWorkspaceDirectoryObserver()
    @State private var fileExplorerWidth: CGFloat = 220
    @State private var fileExplorerDragStartWidth: CGFloat?
    @State private var previousSelectedWorkspaceId: UUID?
    @State private var retiringWorkspaceId: UUID?
    @State private var workspaceHandoffGeneration: UInt64 = 0
    @State private var workspaceHandoffFallbackTask: Task<Void, Never>?
    @State private var didApplyUITestSidebarSelection = false
    @State private var titlebarThemeGeneration: UInt64 = 0
    @State private var sidebarDraggedTabId: UUID?
    @State private var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    @State private var sidebarResizerCursorReleaseWorkItem: DispatchWorkItem?
    @State private var sidebarResizerPointerMonitor: Any?
    @State private var isResizerBandActive = false
    @State private var isSidebarResizerCursorActive = false
    @State private var sidebarResizerCursorStabilizer: DispatchSourceTimer?
    @State private var isCommandPalettePresented = false
    @State private var commandPaletteQuery: String = ""
    @State private var commandPaletteMode: CommandPaletteMode = .commands
    @State private var commandPaletteRenameDraft: String = ""
    @State private var commandPaletteWorkspaceDescriptionDraft: String = ""
    @State private var commandPaletteWorkspaceDescriptionHeight: CGFloat = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
    @State private var commandPaletteSelectedResultIndex: Int = 0
    @State private var commandPaletteSelectionAnchorCommandID: String?
    @State private var commandPaletteHoveredResultIndex: Int?
    @State private var commandPaletteScrollTargetIndex: Int?
    @State private var commandPaletteScrollTargetAnchor: UnitPoint?
    @State private var commandPaletteRestoreFocusTarget: CommandPaletteRestoreFocusTarget?
    @State private var commandPaletteSearchCorpus: [CommandPaletteSearchCorpusEntry<String>] = []
    @State private var commandPaletteSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]
    @State private var commandPaletteSearchCommandsByID: [String: CommandPaletteCommand] = [:]
    @State private var cachedCommandPaletteResults: [CommandPaletteSearchResult] = []
    @State private var commandPaletteVisibleResults: [CommandPaletteSearchResult] = []
    @State private var commandPaletteVisibleResultsScope: CommandPaletteListScope?
    @State private var commandPaletteVisibleResultsFingerprint: Int?
    @State private var cachedCommandPaletteScope: CommandPaletteListScope?
    @State private var cachedCommandPaletteFingerprint: Int?
    @State private var commandPalettePendingDismissFocusTarget: CommandPaletteRestoreFocusTarget?
    @State private var commandPaletteRestoreTimeoutWorkItem: DispatchWorkItem?
    @State private var commandPalettePendingTextSelectionBehavior: CommandPaletteTextSelectionBehavior?
    @State private var commandPaletteSearchTask: Task<Void, Never>?
    @State private var commandPaletteSearchRequestID: UInt64 = 0
    @State private var commandPaletteResolvedSearchRequestID: UInt64 = 0
    @State private var commandPaletteResolvedSearchScope: CommandPaletteListScope?
    @State private var commandPaletteResolvedSearchFingerprint: Int?
    @State private var commandPaletteResolvedMatchingQuery = ""
    @State private var commandPaletteTerminalOpenTargetAvailability: Set<TerminalDirectoryOpenTarget> = []
    @State private var isCommandPaletteSearchPending = false
    @State private var commandPalettePendingActivation: CommandPalettePendingActivation?
    @State private var commandPaletteResultsRevision: UInt64 = 0
    @State private var commandPaletteUsageHistoryByCommandId: [String: CommandPaletteUsageEntry] = [:]
    @State private var isFeedbackComposerPresented = false
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    private var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @AppStorage(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
    private var openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
    @State private var commandPaletteShouldFocusWorkspaceDescriptionEditor = false
    @FocusState private var isCommandPaletteSearchFocused: Bool
    @FocusState private var isCommandPaletteRenameFocused: Bool

    private enum CommandPaletteMode {
        case commands
        case renameInput(CommandPaletteRenameTarget)
        case renameConfirm(CommandPaletteRenameTarget, proposedName: String)
        case workspaceDescriptionInput(CommandPaletteWorkspaceDescriptionTarget)
    }

    private enum CommandPaletteListScope: String {
        case commands
        case switcher
    }

    enum CommandPalettePendingActivation: Equatable {
        case selected(requestID: UInt64, fallbackSelectedIndex: Int, preferredCommandID: String?)
        case command(requestID: UInt64, commandID: String)
    }

    enum CommandPaletteResolvedActivation: Equatable {
        case selected(index: Int)
        case command(commandID: String)
    }

    private struct CommandPaletteRenameTarget: Equatable {
        enum Kind: Equatable {
            case workspace(workspaceId: UUID)
            case tab(workspaceId: UUID, panelId: UUID)
        }

        let kind: Kind
        let currentName: String

        var title: String {
            switch kind {
            case .workspace:
                return String(localized: "commandPalette.rename.workspaceTitle", defaultValue: "Rename Workspace")
            case .tab:
                return String(localized: "commandPalette.rename.tabTitle", defaultValue: "Rename Tab")
            }
        }

        var description: String {
            switch kind {
            case .workspace:
                return String(localized: "commandPalette.rename.workspaceDescription", defaultValue: "Choose a custom workspace name.")
            case .tab:
                return String(localized: "commandPalette.rename.tabDescription", defaultValue: "Choose a custom tab name.")
            }
        }

        var placeholder: String {
            switch kind {
            case .workspace:
                return String(localized: "commandPalette.rename.workspacePlaceholder", defaultValue: "Workspace name")
            case .tab:
                return String(localized: "commandPalette.rename.tabPlaceholder", defaultValue: "Tab name")
            }
        }
    }

    private struct CommandPaletteWorkspaceDescriptionTarget: Equatable {
        let workspaceId: UUID
        let currentDescription: String

        var placeholder: String {
            String(
                localized: "commandPalette.description.workspacePlaceholder",
                defaultValue: "Workspace description"
            )
        }

        var inputHint: String {
            String(
                localized: "commandPalette.description.workspaceInputHint",
                defaultValue: "Press Enter to save. Press Shift-Enter for a new line, or Escape to cancel."
            )
        }
    }

    private struct CommandPaletteRestoreFocusTarget {
        let workspaceId: UUID
        let panelId: UUID
        let intent: PanelFocusIntent
    }

    private enum CommandPaletteInputFocusTarget {
        case search
        case rename
    }

    private enum CommandPaletteTextSelectionBehavior {
        case caretAtEnd
        case selectAll
    }

    private enum CommandPaletteTrailingLabelStyle {
        case shortcut
        case kind
    }

    private struct CommandPaletteTrailingLabel {
        let text: String
        let style: CommandPaletteTrailingLabelStyle
    }

    private struct CommandPaletteInputFocusPolicy {
        let focusTarget: CommandPaletteInputFocusTarget
        let selectionBehavior: CommandPaletteTextSelectionBehavior

        static let search = CommandPaletteInputFocusPolicy(
            focusTarget: .search,
            selectionBehavior: .caretAtEnd
        )
    }

    private struct CommandPaletteCommand: Identifiable {
        let id: String
        let rank: Int
        let title: String
        let subtitle: String
        let shortcutHint: String?
        let kindLabel: String?
        let keywords: [String]
        let dismissOnRun: Bool
        let action: () -> Void

        var searchableTexts: [String] {
            [title, subtitle] + keywords
        }
    }

    private struct CommandPaletteUsageEntry: Codable, Sendable {
        var useCount: Int
        var lastUsedAt: TimeInterval
    }

    static func tmuxWorkspacePaneExactRect(
        for panel: Panel,
        in contentView: NSView
    ) -> CGRect? {
        let targetView: NSView?
        switch panel {
        case let terminal as TerminalPanel:
            targetView = terminal.hostedView
        case let browser as BrowserPanel:
            targetView = browser.webView
        default:
            targetView = nil
        }
        guard let targetView else { return nil }
        return tmuxWorkspacePaneExactRect(for: targetView, in: contentView)
    }

    static func tmuxWorkspacePaneExactRect(
        for targetView: NSView,
        in contentView: NSView
    ) -> CGRect? {
        guard let contentWindow = contentView.window,
              let targetWindow = targetView.window,
              contentWindow === targetWindow,
              targetView.superview != nil else {
            return nil
        }

        let rectInWindow = targetView.convert(targetView.bounds, to: nil)
        let rectInContent = contentView.convert(rectInWindow, from: nil)
        guard rectInContent.width > 1, rectInContent.height > 1 else { return nil }
        return rectInContent
    }

    static func preferredTmuxWorkspacePaneWindowOverlayRect(
        exactRect: CGRect?,
        paneRect: CGRect?
    ) -> CGRect? {
        guard let paneRect else { return exactRect }
        guard let exactRect,
              exactRect.width > 1,
              exactRect.height > 1 else {
            return paneRect
        }

        let tolerance: CGFloat = 0.5
        let exactFitsWithinPane =
            exactRect.minX >= paneRect.minX - tolerance &&
            exactRect.maxX <= paneRect.maxX + tolerance &&
            exactRect.minY >= paneRect.minY - tolerance &&
            exactRect.maxY <= paneRect.maxY + tolerance
        return exactFitsWithinPane ? exactRect : paneRect
    }

    private func tmuxWorkspacePaneWindowOverlayState(for window: NSWindow) -> TmuxWorkspacePaneOverlayRenderState? {
        guard TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay,
              let workspace = tabManager.selectedWorkspace else { return nil }
        let layoutSnapshot = WorkspaceContentView.effectiveTmuxLayoutSnapshot(
            cachedSnapshot: workspace.tmuxLayoutSnapshot,
            liveSnapshot: workspace.bonsplitController.layoutSnapshot()
        )
        let contentView = window.contentView

        let unreadRects: [CGRect]
        if let layoutSnapshot, let contentView {
            unreadRects = layoutSnapshot.panes.compactMap { pane in
                guard let selectedTabId = pane.selectedTabId,
                      let tabUUID = UUID(uuidString: selectedTabId),
                      let panelId = workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID)),
                      let panel = workspace.panels[panelId] else {
                    return nil
                }

                let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panelId
                    ),
                    isManuallyUnread: workspace.manualUnreadPanelIds.contains(panelId)
                )
                guard shouldShowUnread else { return nil }

                let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                    layoutSnapshot: layoutSnapshot,
                    paneId: workspace.paneId(forPanelId: panelId)
                )
                let exactRect = Self.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
                return Self.preferredTmuxWorkspacePaneWindowOverlayRect(
                    exactRect: exactRect,
                    paneRect: paneRect
                )
            }
        } else {
            unreadRects = WorkspaceContentView.tmuxWorkspacePaneWindowUnreadRects(
                workspace: workspace,
                notificationStore: notificationStore,
                layoutSnapshot: layoutSnapshot
            )
        }

        let flashRect: CGRect?
        if let panelId = workspace.tmuxWorkspaceFlashPanelId,
           let panel = workspace.panels[panelId],
           let contentView {
            let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: workspace.paneId(forPanelId: panelId)
            )
            let exactRect = Self.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
            flashRect = Self.preferredTmuxWorkspacePaneWindowOverlayRect(
                exactRect: exactRect,
                paneRect: paneRect
            )
        } else {
            flashRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: workspace.tmuxWorkspaceFlashPanelId.flatMap { workspace.paneId(forPanelId: $0) }
            )
        }

        return TmuxWorkspacePaneOverlayRenderState(
            workspaceId: workspace.id,
            unreadRects: unreadRects,
            flashRect: flashRect,
            flashToken: workspace.tmuxWorkspaceFlashToken,
            flashReason: workspace.tmuxWorkspaceFlashReason
        )
    }

    private struct CommandPaletteContextSnapshot {
        private var boolValues: [String: Bool] = [:]
        private var stringValues: [String: String] = [:]

        mutating func setBool(_ key: String, _ value: Bool) {
            boolValues[key] = value
        }

        mutating func setString(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else {
                stringValues.removeValue(forKey: key)
                return
            }
            stringValues[key] = value
        }

        func bool(_ key: String) -> Bool {
            boolValues[key] ?? false
        }

        func string(_ key: String) -> String? {
            stringValues[key]
        }

        func fingerprint() -> Int {
            ContentView.commandPaletteContextFingerprint(
                boolValues: boolValues,
                stringValues: stringValues
            )
        }
    }

    private struct CommandPaletteCommandsContext {
        let snapshot: CommandPaletteContextSnapshot
    }

    private enum CommandPaletteContextKeys {
        static let hasWorkspace = "workspace.hasSelection"
        static let workspaceName = "workspace.name"
        static let workspaceHasCustomName = "workspace.hasCustomName"
        static let workspaceHasCustomDescription = "workspace.hasCustomDescription"
        static let workspaceMinimalModeEnabled = "workspace.minimalModeEnabled"
        static let workspaceShouldPin = "workspace.shouldPin"
        static let workspaceHasPullRequests = "workspace.hasPullRequests"
        static let workspaceHasSplits = "workspace.hasSplits"
        static let workspaceHasPeers = "workspace.hasPeers"
        static let workspaceHasAbove = "workspace.hasAbove"
        static let workspaceHasBelow = "workspace.hasBelow"
        static let workspaceHasUnread = "workspace.hasUnread"
        static let workspaceHasRead = "workspace.hasRead"

        static let hasFocusedPanel = "panel.hasFocus"
        static let panelName = "panel.name"
        static let panelIsBrowser = "panel.isBrowser"
        static let panelIsTerminal = "panel.isTerminal"
        static let panelHasCustomName = "panel.hasCustomName"
        static let panelShouldPin = "panel.shouldPin"
        static let panelHasUnread = "panel.hasUnread"

        static let updateHasAvailable = "update.hasAvailable"
        static let cliInstalledInPATH = "cli.installedInPATH"

        static func terminalOpenTargetAvailable(_ target: TerminalDirectoryOpenTarget) -> String {
            "terminal.openTarget.\(target.rawValue).available"
        }
    }

    private struct CommandPaletteCommandContribution {
        let commandId: String
        let title: (CommandPaletteContextSnapshot) -> String
        let subtitle: (CommandPaletteContextSnapshot) -> String
        let shortcutHint: String?
        let keywords: [String]
        let dismissOnRun: Bool
        let when: (CommandPaletteContextSnapshot) -> Bool
        let enablement: (CommandPaletteContextSnapshot) -> Bool

        init(
            commandId: String,
            title: @escaping (CommandPaletteContextSnapshot) -> String,
            subtitle: @escaping (CommandPaletteContextSnapshot) -> String,
            shortcutHint: String? = nil,
            keywords: [String] = [],
            dismissOnRun: Bool = true,
            when: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true },
            enablement: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true }
        ) {
            self.commandId = commandId
            self.title = title
            self.subtitle = subtitle
            self.shortcutHint = shortcutHint
            self.keywords = keywords
            self.dismissOnRun = dismissOnRun
            self.when = when
            self.enablement = enablement
        }
    }

    private struct CommandPaletteHandlerRegistry {
        private var handlers: [String: () -> Void] = [:]

        mutating func register(commandId: String, handler: @escaping () -> Void) {
            handlers[commandId] = handler
        }

        func handler(for commandId: String) -> (() -> Void)? {
            handlers[commandId]
        }
    }

    private struct CommandPaletteSearchResult: Identifiable {
        let command: CommandPaletteCommand
        let score: Int
        let titleMatchIndices: Set<Int>

        var id: String { command.id }
    }

    private struct CommandPaletteResolvedSearchMatch: Sendable {
        let commandID: String
        let score: Int
        let titleMatchIndices: Set<Int>
    }

    private struct CommandPaletteSwitcherWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let selectedWorkspaceId: UUID?
        let windowLabel: String?
    }

    struct CommandPaletteSwitcherFingerprintWorkspace: Sendable {
        let id: UUID
        let displayName: String
        let metadata: CommandPaletteSwitcherSearchMetadata
        let surfaces: [CommandPaletteSwitcherFingerprintSurface]
    }

    struct CommandPaletteSwitcherFingerprintSurface: Sendable {
        let id: UUID
        let displayName: String
        let kindLabel: String
        let metadata: CommandPaletteSwitcherSearchMetadata
    }

    struct CommandPaletteSwitcherFingerprintContext: Sendable {
        let windowId: UUID
        let windowLabel: String?
        let selectedWorkspaceId: UUID?
        let workspaces: [CommandPaletteSwitcherFingerprintWorkspace]
    }

    private static let fixedSidebarResizeCursor = NSCursor(
        image: NSCursor.resizeLeftRight.image,
        hotSpot: NSCursor.resizeLeftRight.hotSpot
    )
    private static let commandPaletteUsageDefaultsKey = "commandPalette.commandUsage.v1"
    nonisolated private static let commandPaletteCommandsPrefix = ">"
    private static let commandPaletteVisiblePreviewResultLimit = 48
    private static let commandPaletteVisiblePreviewCandidateLimit = 192
    private static let minimumSidebarWidth: CGFloat = CGFloat(SessionPersistencePolicy.minimumSidebarWidth)
    private static let maximumSidebarWidthRatio: CGFloat = 1.0 / 3.0

    private enum SidebarResizerHandle: Hashable {
        case divider
        case explorerDivider
    }

    /// Returns the current drag width, start width capture, width update, and drag end cleanup for a resizer handle.
    private func resizerConfig(for handle: SidebarResizerHandle, availableWidth: CGFloat) -> (
        currentWidth: CGFloat,
        captureStart: () -> Void,
        updateWidth: (CGFloat) -> Void,
        finishDrag: () -> Void
    ) {
        switch handle {
        case .divider:
            return (
                currentWidth: sidebarWidth,
                captureStart: { sidebarDragStartWidth = sidebarWidth },
                updateWidth: { translation in
                    let startWidth = sidebarDragStartWidth ?? sidebarWidth
                    let nextWidth = Self.clampedSidebarWidth(
                        startWidth + translation,
                        maximumWidth: maxSidebarWidth(availableWidth: availableWidth)
                    )
                    withTransaction(Transaction(animation: nil)) {
                        sidebarWidth = nextWidth
                    }
                },
                finishDrag: { sidebarDragStartWidth = nil }
            )
        case .explorerDivider:
            return (
                currentWidth: fileExplorerWidth,
                captureStart: { fileExplorerDragStartWidth = fileExplorerWidth },
                updateWidth: { translation in
                    let startWidth = fileExplorerDragStartWidth ?? fileExplorerWidth
                    let nextWidth = min(500, max(150, startWidth - translation))
                    withTransaction(Transaction(animation: nil)) {
                        fileExplorerWidth = nextWidth
                    }
                },
                finishDrag: {
                    fileExplorerDragStartWidth = nil
                    fileExplorerState.width = fileExplorerWidth
                }
            )
        }
    }

    private var sidebarResizerSidebarHitWidth: CGFloat {
        SidebarResizeInteraction.sidebarSideHitWidth
    }

    private var sidebarResizerContentHitWidth: CGFloat {
        SidebarResizeInteraction.contentSideHitWidth
    }

    private func maxSidebarWidth(availableWidth: CGFloat? = nil) -> CGFloat {
        let resolvedAvailableWidth = availableWidth
            ?? observedWindow?.contentView?.bounds.width
            ?? observedWindow?.contentLayoutRect.width
            ?? NSApp.keyWindow?.contentView?.bounds.width
            ?? NSApp.keyWindow?.contentLayoutRect.width
        if let resolvedAvailableWidth, resolvedAvailableWidth > 0 {
            return max(Self.minimumSidebarWidth, resolvedAvailableWidth * Self.maximumSidebarWidthRatio)
        }

        let fallbackScreenWidth = NSApp.keyWindow?.screen?.frame.width
            ?? NSScreen.main?.frame.width
            ?? 1920
        return max(Self.minimumSidebarWidth, fallbackScreenWidth * Self.maximumSidebarWidthRatio)
    }

    static func clampedSidebarWidth(_ candidate: CGFloat, maximumWidth: CGFloat) -> CGFloat {
        let minimumWidth = Self.minimumSidebarWidth
        let sanitizedMaximumWidth = max(minimumWidth, maximumWidth.isFinite ? maximumWidth : minimumWidth)
        guard candidate.isFinite else {
            return CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
        }
        return max(minimumWidth, min(sanitizedMaximumWidth, candidate))
    }

    private func clampSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = Self.clampedSidebarWidth(
            sidebarWidth,
            maximumWidth: maxSidebarWidth(availableWidth: availableWidth)
        )
        guard abs(nextWidth - sidebarWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            sidebarWidth = nextWidth
        }
    }

    private func normalizedSidebarWidth(_ candidate: CGFloat) -> CGFloat {
        Self.clampedSidebarWidth(candidate, maximumWidth: maxSidebarWidth())
    }

    private func activateSidebarResizerCursor() {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        sidebarResizerCursorReleaseWorkItem = nil
        isSidebarResizerCursorActive = true
        Self.fixedSidebarResizeCursor.set()
    }

    private func releaseSidebarResizerCursorIfNeeded(force: Bool = false) {
        let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let shouldKeepCursor = !force
            && (isResizerDragging || isResizerBandActive || !hoveredResizerHandles.isEmpty || isLeftMouseButtonDown)
        guard !shouldKeepCursor else { return }
        guard isSidebarResizerCursorActive else { return }
        isSidebarResizerCursorActive = false
        NSCursor.arrow.set()
    }

    private func scheduleSidebarResizerCursorRelease(force: Bool = false, delay: TimeInterval = 0) {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            sidebarResizerCursorReleaseWorkItem = nil
            releaseSidebarResizerCursorIfNeeded(force: force)
        }
        sidebarResizerCursorReleaseWorkItem = workItem
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    private func dividerBandContains(pointInContent point: NSPoint, contentBounds: NSRect) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        let minX = sidebarWidth - sidebarResizerSidebarHitWidth
        let maxX = sidebarWidth + sidebarResizerContentHitWidth
        return point.x >= minX && point.x <= maxX
    }

    private func updateSidebarResizerBandState(using event: NSEvent? = nil) {
        guard sidebarState.isVisible,
              let window = observedWindow,
              let contentView = window.contentView else {
            isResizerBandActive = false
            scheduleSidebarResizerCursorRelease(force: true)
            return
        }

        // Use live global pointer location instead of per-event coordinates.
        // Overlapping tracking areas (notably WKWebView) can deliver stale/jittery
        // event locations during cursor updates, which causes visible cursor flicker.
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        let isInDividerBand = dividerBandContains(pointInContent: pointInContent, contentBounds: contentView.bounds)
        isResizerBandActive = isInDividerBand

        if isInDividerBand || isResizerDragging {
            activateSidebarResizerCursor()
            startSidebarResizerCursorStabilizer()
            // AppKit cursorUpdate handlers from overlapped portal/web views can run
            // after our local monitor callback and temporarily reset the cursor.
            // Re-assert on the next runloop turn to keep the resize cursor stable.
            DispatchQueue.main.async {
                Self.fixedSidebarResizeCursor.set()
            }
        } else {
            stopSidebarResizerCursorStabilizer()
            scheduleSidebarResizerCursorRelease()
        }
    }

    private func startSidebarResizerCursorStabilizer() {
        guard sidebarResizerCursorStabilizer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler {
            updateSidebarResizerBandState()
            if isResizerBandActive || isResizerDragging {
                Self.fixedSidebarResizeCursor.set()
            } else {
                stopSidebarResizerCursorStabilizer()
            }
        }
        sidebarResizerCursorStabilizer = timer
        timer.resume()
    }

    private func stopSidebarResizerCursorStabilizer() {
        sidebarResizerCursorStabilizer?.cancel()
        sidebarResizerCursorStabilizer = nil
    }

    private func installSidebarResizerPointerMonitorIfNeeded() {
        guard sidebarResizerPointerMonitor == nil else { return }
        observedWindow?.acceptsMouseMovedEvents = true
        sidebarResizerPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .mouseEntered,
                .mouseExited,
                .cursorUpdate,
                .appKitDefined,
                .systemDefined,
                .leftMouseDown,
                .leftMouseUp,
                .leftMouseDragged,
            ]
        ) { event in
            updateSidebarResizerBandState(using: event)
            let shouldOverrideCursorEvent: Bool = {
                switch event.type {
                case .cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited, .appKitDefined, .systemDefined:
                    return true
                default:
                    return false
                }
            }()
            if shouldOverrideCursorEvent, (isResizerBandActive || isResizerDragging) {
                // Consume hover motion in divider band so overlapped views cannot
                // continuously reassert their own cursor while we are resizing.
                activateSidebarResizerCursor()
                Self.fixedSidebarResizeCursor.set()
                return nil
            }
            return event
        }
        updateSidebarResizerBandState()
    }

    private func removeSidebarResizerPointerMonitor() {
        if let monitor = sidebarResizerPointerMonitor {
            NSEvent.removeMonitor(monitor)
            sidebarResizerPointerMonitor = nil
        }
        isResizerBandActive = false
        isSidebarResizerCursorActive = false
        stopSidebarResizerCursorStabilizer()
        scheduleSidebarResizerCursorRelease(force: true)
    }

    private func sidebarResizerHandleOverlay(
        _ handle: SidebarResizerHandle,
        width: CGFloat,
        availableWidth: CGFloat,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredResizerHandles.insert(handle)
                    activateSidebarResizerCursor()
                } else {
                    hoveredResizerHandles.remove(handle)
                    let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    if isLeftMouseButtonDown {
                        // Keep resize cursor pinned through mouse-down so AppKit
                        // cursorUpdate events from overlapping views do not flash arrow.
                        activateSidebarResizerCursor()
                    } else {
                        // Give mouse-down + drag-start callbacks time to establish state
                        // before any cursor pop is attempted.
                        scheduleSidebarResizerCursorRelease(delay: 0.05)
                    }
                }
                updateSidebarResizerBandState()
            }
            .onDisappear {
                hoveredResizerHandles.remove(handle)
                if isResizerDragging {
                    TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                    isResizerDragging = false
                }
                sidebarDragStartWidth = nil
                isResizerBandActive = false
                scheduleSidebarResizerCursorRelease(force: true)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let config = resizerConfig(for: handle, availableWidth: availableWidth)
                        if !isResizerDragging {
                            TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
                            isResizerDragging = true
                            config.captureStart()
                        }
                        activateSidebarResizerCursor()
                        config.updateWidth(value.translation.width)
                    }
                    .onEnded { _ in
                        if isResizerDragging {
                            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                            isResizerDragging = false
                            let config = resizerConfig(for: handle, availableWidth: availableWidth)
                            config.finishDrag()
                        }
                        activateSidebarResizerCursor()
                        scheduleSidebarResizerCursorRelease()
                    }
            )
            .modifier(SidebarResizerAccessibilityModifier(accessibilityIdentifier: accessibilityIdentifier))
    }

    private var sidebarResizerOverlay: some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width)
            let dividerX = min(max(sidebarWidth, 0), totalWidth)
            let leadingWidth = max(0, dividerX - sidebarResizerSidebarHitWidth)

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leadingWidth)
                    .allowsHitTesting(false)

                sidebarResizerHandleOverlay(
                    .divider,
                    width: SidebarResizeInteraction.totalHitWidth,
                    availableWidth: totalWidth,
                    accessibilityIdentifier: "SidebarResizer"
                )

                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
            .frame(width: totalWidth, height: proxy.size.height, alignment: .leading)
            .onAppear {
                clampSidebarWidthIfNeeded(availableWidth: totalWidth)
            }
            .onChange(of: totalWidth) {
                clampSidebarWidthIfNeeded(availableWidth: totalWidth)
            }
        }
    }

    private var sidebarView: some View {
        VerticalTabsSidebar(
            updateViewModel: updateViewModel,
            fileExplorerState: fileExplorerState,
            onSendFeedback: presentFeedbackComposer,
            selection: $sidebarSelectionState.selection,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// Space at top of content area for the titlebar. This must be at least the actual titlebar
    /// height; otherwise controls like Bonsplit tab dragging can be interpreted as window drags.
    @State private var titlebarPadding: CGFloat = 32
    /// SwiftUI WindowGroup windows can still report a titlebar safe area; manually created
    /// main windows use MainWindowHostingView and report zero.
    @State private var hostingSafeAreaTop: CGFloat = 0
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var effectiveTitlebarPadding: CGFloat {
        Self.effectiveTitlebarPadding(
            isMinimalMode: isMinimalMode,
            isFullScreen: isFullScreen,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        )
    }

    static func effectiveTitlebarPadding(
        isMinimalMode: Bool,
        isFullScreen: Bool,
        titlebarPadding: CGFloat,
        hostingSafeAreaTop: CGFloat
    ) -> CGFloat {
        guard isMinimalMode else { return titlebarPadding }
        guard !isFullScreen else { return 0 }
        return -max(0, min(titlebarPadding, hostingSafeAreaTop))
    }

    private var terminalContent: some View {
        let mountedWorkspaceIdSet = Set(mountedWorkspaceIds)
        let mountedWorkspaces = tabManager.tabs.filter { mountedWorkspaceIdSet.contains($0.id) }
        let selectedWorkspaceId = tabManager.selectedTabId
        let retiringWorkspaceId = self.retiringWorkspaceId

        return ZStack {
            ZStack {
                ForEach(mountedWorkspaces) { tab in
                    let isSelectedWorkspace = selectedWorkspaceId == tab.id
                    let isRetiringWorkspace = retiringWorkspaceId == tab.id
                    let shouldPrimeInBackground = tabManager.pendingBackgroundWorkspaceLoadIds.contains(tab.id)
                    let presentation = MountedWorkspacePresentationPolicy.resolve(
                        isSelectedWorkspace: isSelectedWorkspace,
                        isRetiringWorkspace: isRetiringWorkspace,
                        shouldPrimeInBackground: shouldPrimeInBackground
                    )
                    // Keep the retiring workspace visible during handoff, but never input-active.
                    // Allowing both selected+retiring workspaces to be input-active lets the
                    // old workspace steal first responder (notably with WKWebView), which can
                    // delay handoff completion and make browser returns feel laggy.
                    let isInputActive = isSelectedWorkspace
                    let portalPriority = isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0)
                    WorkspaceContentView(
                        workspace: tab,
                        isWorkspaceVisible: presentation.isPanelVisible,
                        isWorkspaceInputActive: isInputActive,
                        isFullScreen: isFullScreen,
                        workspacePortalPriority: portalPriority,
                        onThemeRefreshRequest: { reason, eventId, source, payloadHex in
                            scheduleTitlebarThemeRefreshFromWorkspace(
                                workspaceId: tab.id,
                                reason: reason,
                                backgroundEventId: eventId,
                                backgroundSource: source,
                                notificationPayloadHex: payloadHex
                            )
                        }
                    )
                    .opacity(presentation.renderOpacity)
                    .allowsHitTesting(isSelectedWorkspace)
                    .accessibilityHidden(!presentation.isRenderedVisible)
                    .zIndex(isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0))
                    .task(id: shouldPrimeInBackground ? tab.id : nil) {
                        await primeBackgroundWorkspaceIfNeeded(workspaceId: tab.id)
                    }
                }
            }
            .opacity(sidebarSelectionState.selection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelectionState.selection == .tabs)
            .accessibilityHidden(sidebarSelectionState.selection != .tabs)

            NotificationsPage(selection: $sidebarSelectionState.selection)
                .opacity(sidebarSelectionState.selection == .notifications ? 1 : 0)
                .allowsHitTesting(sidebarSelectionState.selection == .notifications)
                .accessibilityHidden(sidebarSelectionState.selection != .notifications)
        }
        .padding(.top, effectiveTitlebarPadding)
        .overlay(alignment: .top) {
            if !isMinimalMode {
                // Titlebar overlay is only over terminal content, not the sidebar.
                customTitlebar
            }
        }
    }

    private var terminalContentWithSidebarDropOverlay: some View {
        // File explorer is always in the view tree. Visibility is controlled by
        // frame width (0 when hidden), avoiding SwiftUI view insertion/removal
        // and all associated transition animations.
        let explorerVisible = fileExplorerState.isVisible
        return HStack(spacing: 0) {
            terminalContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .overlay {
                    SidebarExternalDropOverlay(draggedTabId: sidebarDraggedTabId)
                }
            if explorerVisible {
                Divider()
            }
            RightSidebarPanelView(
                fileExplorerStore: fileExplorerStore,
                fileExplorerState: fileExplorerState,
                sessionIndexStore: sessionIndexStore,
                onResumeSession: { entry in
                    resumeSession(entry: entry)
                }
            )
                .frame(width: explorerVisible ? fileExplorerWidth : 0)
                .clipped()
                .allowsHitTesting(explorerVisible)
                .accessibilityHidden(!explorerVisible)
                .overlay(alignment: .leading) {
                    if explorerVisible {
                        fileExplorerResizerHandle
                    }
                }
        }
        .transaction { $0.animation = nil }
        .onAppear {
            fileExplorerWidth = fileExplorerState.width
        }
        .onChange(of: fileExplorerState.width) { newValue in
            if fileExplorerDragStartWidth == nil {
                fileExplorerWidth = newValue
            }
        }
    }

    private var fileExplorerResizerHandle: some View {
        sidebarResizerHandleOverlay(
            .explorerDivider,
            width: SidebarResizeInteraction.totalHitWidth,
            availableWidth: observedWindow?.contentView?.bounds.width ?? 1920
        )
    }

    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarMatchTerminalBackground") private var sidebarMatchTerminalBackground = false

    // Background glass settings
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = false
    @AppStorage("debugTitlebarLeadingExtra") private var debugTitlebarLeadingExtra: Double = 0

    @State private var titlebarLeadingInset: CGFloat = 12
    private var windowIdentifier: String { "cmux.main.\(windowId.uuidString)" }
    private var fakeTitlebarTextColor: Color {
        _ = titlebarThemeGeneration
        let ghosttyBackground = GhosttyApp.shared.defaultBackgroundColor
        return ghosttyBackground.isLightColor
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.82)
    }
    private var fullscreenControls: some View {
        TitlebarControlsView(
            notificationStore: TerminalNotificationStore.shared,
            viewModel: fullscreenControlsViewModel,
            onToggleSidebar: { sidebarState.toggle() },
            onToggleNotifications: { [fullscreenControlsViewModel] in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: fullscreenControlsViewModel.notificationsAnchorView
                )
            },
            onNewTab: { tabManager.addTab() },
            visibilityMode: .alwaysVisible
        )
    }

    private var customTitlebar: some View {
        ZStack {
            // Enable window dragging from the titlebar strip without making the entire content
            // view draggable (which breaks drag gestures like tab reordering).
            WindowDragHandleView()

            TitlebarLeadingInsetReader(inset: $titlebarLeadingInset)
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                if isFullScreen && !sidebarState.isVisible {
                    fullscreenControls
                }

                // Draggable folder icon + focused command name
                if let directory = focusedDirectory {
                    DraggableFolderIcon(directory: directory)
                        .padding(.leading, -6)
                }

                Text(titlebarText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(fakeTitlebarTextColor)
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer()

            }
            .frame(height: 28)
            .padding(.top, 2)
            .padding(.leading, (isFullScreen && !sidebarState.isVisible) ? 8 : (sidebarState.isVisible ? 12 : titlebarLeadingInset + CGFloat(debugTitlebarLeadingExtra)))
            .padding(.trailing, 8)
        }
        .frame(height: titlebarPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(TitlebarDoubleClickMonitorView())
        .background({
            // The terminal background is provided by a single CALayer
            // (backgroundView in GhosttySurfaceScrollView), so the titlebar
            // opacity matches the configured value directly.
            let alpha = CGFloat(GhosttyApp.shared.defaultBackgroundOpacity)
            return TitlebarLayerBackground(
                backgroundColor: GhosttyApp.shared.defaultBackgroundColor,
                opacity: alpha
            )
        }())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    private func syncTrafficLightInset() {
        let inset: CGFloat = (isMinimalMode && !sidebarState.isVisible && !isFullScreen) ? 80 : 0
        tabManager.syncWorkspaceTabBarLeadingInset(inset)
    }

    private func updateTitlebarText() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            if !titlebarText.isEmpty {
                titlebarText = ""
            }
            return
        }
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if titlebarText != title {
            titlebarText = title
        }
    }

    private func scheduleTitlebarTextRefresh() {
        titlebarTextUpdateCoalescer.signal {
            updateTitlebarText()
        }
    }

    private func scheduleTitlebarThemeRefresh(
        reason: String,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousGeneration = titlebarThemeGeneration
        titlebarThemeGeneration &+= 1
        if GhosttyApp.shared.backgroundLogEnabled {
            let eventLabel = backgroundEventId.map(String.init) ?? "nil"
            let sourceLabel = backgroundSource ?? "nil"
            let payloadLabel = notificationPayloadHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh scheduled reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousGeneration=\(previousGeneration) generation=\(titlebarThemeGeneration) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        }
    }

    private func scheduleTitlebarThemeRefreshFromWorkspace(
        workspaceId: UUID,
        reason: String,
        backgroundEventId: UInt64?,
        backgroundSource: String?,
        notificationPayloadHex: String?
    ) {
        guard tabManager.selectedTabId == workspaceId else {
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh skipped workspace=\(workspaceId.uuidString) selected=\(tabManager.selectedTabId?.uuidString ?? "nil") reason=\(reason)"
            )
            return
        }

        scheduleTitlebarThemeRefresh(
            reason: reason,
            backgroundEventId: backgroundEventId,
            backgroundSource: backgroundSource,
            notificationPayloadHex: notificationPayloadHex
        )
    }

    private func resumeSession(entry: SessionEntry) {
        let inputWithReturn = entry.resumeCommand + "\n"
        let targetCwd = entry.cwd

        // Smart placement: if the focused workspace's tracked cwd matches, open a
        // new tab inside that workspace. Otherwise create a new workspace.
        // Remote workspaces are excluded from cwd-match: a session indexed from
        // the local filesystem must not be resumed inside a remote shell just
        // because the path string happens to coincide.
        let selected = tabManager.selectedWorkspace
        let selectedTab = tabManager.selectedTabId.flatMap { id in
            tabManager.tabs.first(where: { $0.id == id })
        }
        let isRemoteSelection = selectedTab?.isRemoteWorkspace ?? false
        let workspaceCwd = selected?.currentDirectory
        let pwdMatches: Bool = {
            guard !isRemoteSelection,
                  let targetCwd, !targetCwd.isEmpty,
                  let workspaceCwd, !workspaceCwd.isEmpty else { return false }
            let lhs = (targetCwd as NSString).standardizingPath
            let rhs = (workspaceCwd as NSString).standardizingPath
            return lhs == rhs
        }()

        if pwdMatches,
           let workspace = selected,
           let paneId = workspace.bonsplitController.focusedPaneId {
            workspace.newTerminalSurface(
                inPane: paneId,
                focus: true,
                workingDirectory: targetCwd,
                initialInput: inputWithReturn
            )
            return
        }

        tabManager.addWorkspace(
            workingDirectory: targetCwd,
            initialTerminalInput: inputWithReturn
        )
    }

    private func syncFileExplorerDirectory() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            // No selection means we have no local cwd to scope by; clear so the
            // sessions panel doesn't keep filtering by a stale previous tab.
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            return
        }

        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            return
        }

        fileExplorerStore.showHiddenFiles = true
        if !tab.isRemoteWorkspace {
            sessionIndexStore.setCurrentDirectoryIfChanged(dir)
        } else {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
        }

        if tab.isRemoteWorkspace {
            let config = tab.remoteConfiguration
            let remotePath = tab.remoteDaemonStatus.remotePath
            let isReady = tab.remoteDaemonStatus.state == .ready
            let homePath = remotePath.flatMap { path -> String? in
                let components = dir.split(separator: "/")
                if components.count >= 2, components[0] == "home" {
                    return "/home/\(components[1])"
                }
                if dir.hasPrefix("/root") {
                    return "/root"
                }
                return nil
            } ?? ""

            #if DEBUG
            dlog("fileExplorer.sync remote dir=\(dir) ready=\(isReady) dest=\(config?.destination ?? "nil")")
            #endif

            if let existingProvider = fileExplorerStore.provider as? SSHFileExplorerProvider,
               existingProvider.destination == config?.destination {
                existingProvider.updateAvailability(isReady, homePath: isReady ? homePath : nil)
                if isReady {
                    // Only reload if the path actually changed
                    let pathChanged = fileExplorerStore.rootPath != dir
                    fileExplorerStore.setRootPath(dir)
                    if pathChanged {
                        fileExplorerStore.hydrateExpandedNodes()
                    }
                }
            } else if let config {
                let provider = SSHFileExplorerProvider(
                    destination: config.destination,
                    port: config.port,
                    identityFile: config.identityFile,
                    sshOptions: config.sshOptions,
                    homePath: homePath,
                    isAvailable: isReady
                )
                fileExplorerStore.setProvider(provider)
                fileExplorerStore.setRootPath(dir)
            }
        } else {
            if !(fileExplorerStore.provider is LocalFileExplorerProvider) {
                fileExplorerStore.setProvider(LocalFileExplorerProvider())
            }
            fileExplorerStore.setRootPath(dir)
        }
    }

    private var focusedDirectory: String? {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            return nil
        }
        // Use focused panel's directory if available
        if let focusedPanelId = tab.focusedPanelId,
           let panelDir = tab.panelDirectories[focusedPanelId] {
            let trimmed = panelDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    private var contentAndSidebarLayout: AnyView {
        let layout: AnyView
        // When matching terminal background, use HStack so both sidebar and terminal
        // sit directly on the window background with no intermediate layers.
        let useWithinWindow = sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue
            && !sidebarMatchTerminalBackground
        if useWithinWindow {
            // Overlay mode: terminal extends full width, sidebar on top
            // This allows withinWindow blur to see the terminal content
            layout = AnyView(
                ZStack(alignment: .leading) {
                    terminalContentWithSidebarDropOverlay
                        .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
                    if sidebarState.isVisible {
                        sidebarView
                    }
                }
            )
        } else {
            // Standard HStack mode for behindWindow blur
            layout = AnyView(
                HStack(spacing: 0) {
                    if sidebarState.isVisible {
                        sidebarView
                    }
                    terminalContentWithSidebarDropOverlay
                }
            )
        }

        return AnyView(
            layout
                .overlay(alignment: .leading) {
                    if sidebarState.isVisible {
                        sidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
        )
    }

    var body: some View {
        var view = AnyView(
            contentAndSidebarLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if isFullScreen && sidebarState.isVisible && !isMinimalMode {
                        fullscreenControls
                            .padding(.leading, 10)
                            .padding(.top, 4)
                    }
                }
                .frame(minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth), minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight))
                .background(Color.clear)
        )

        view = AnyView(view.onAppear {
            selectedWorkspaceDirectoryObserver.wire(tabManager: tabManager)
            tabManager.applyWindowBackgroundForSelectedTab()
            reconcileMountedWorkspaceIds()
            previousSelectedWorkspaceId = tabManager.selectedTabId
            installSidebarResizerPointerMonitorIfNeeded()
            let restoredWidth = normalizedSidebarWidth(sidebarState.persistedWidth)
            if abs(sidebarWidth - restoredWidth) > 0.5 {
                sidebarWidth = restoredWidth
            }
            if abs(sidebarState.persistedWidth - restoredWidth) > 0.5 {
                sidebarState.persistedWidth = restoredWidth
            }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)
            updateTitlebarText()
            syncTrafficLightInset()

            // Startup recovery (#399): if session restore or a race condition leaves the
            // view in a broken state (empty tabs, no selection, unmounted workspaces),
            // detect and recover after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak tabManager] in
                guard let tabManager else { return }
                var didRecover = false

                // Ensure there is at least one workspace.
                if tabManager.tabs.isEmpty {
                    tabManager.addWorkspace()
                    didRecover = true
                }

                // Ensure selectedTabId points to an existing workspace.
                if tabManager.selectedTabId == nil || !tabManager.tabs.contains(where: { $0.id == tabManager.selectedTabId }) {
                    tabManager.selectedTabId = tabManager.tabs.first?.id
                    didRecover = true
                }

                // Ensure mountedWorkspaceIds is populated.
                if mountedWorkspaceIds.isEmpty || !mountedWorkspaceIds.contains(where: { id in tabManager.tabs.contains { $0.id == id } }) {
                    reconcileMountedWorkspaceIds()
                    didRecover = true
                }

                // Ensure sidebar selection is valid.
                if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                    didRecover = true
                }

                syncSidebarSelectedWorkspaceIds()
                applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)

                if didRecover {
#if DEBUG
                    dlog("startup.recovery tabCount=\(tabManager.tabs.count) selected=\(tabManager.selectedTabId?.uuidString.prefix(8) ?? "nil") mounted=\(mountedWorkspaceIds.count)")
#endif
                    sentryBreadcrumb("startup.recovery", data: [
                        "tabCount": tabManager.tabs.count,
                        "selectedTabId": tabManager.selectedTabId?.uuidString ?? "nil",
                        "mountedCount": mountedWorkspaceIds.count
                    ])
                }
            }
        })

        view = AnyView(view.onChange(of: tabManager.selectedTabId) { newValue in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.view.selectedChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newValue))"
                )
            } else {
                dlog("ws.view.selectedChange id=none selected=\(debugShortWorkspaceId(newValue))")
            }
#endif
            tabManager.applyWindowBackgroundForSelectedTab()
            startWorkspaceHandoffIfNeeded(newSelectedId: newValue)
            reconcileMountedWorkspaceIds(selectedId: newValue)
            guard let newValue else { return }
            if selectedTabIds.count <= 1 {
                selectedTabIds = [newValue]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == newValue }
            }
            updateTitlebarText()
        })

        view = AnyView(view.onChange(of: selectedTabIds) { _ in
            syncSidebarSelectedWorkspaceIds()
        })

        // File explorer: keep the Combine subscription stable across body re-evaluations.
        view = AnyView(view.onChange(of: selectedWorkspaceDirectoryObserver.directoryChangeGeneration) { _ in
            syncFileExplorerDirectory()
        })

        view = AnyView(view.onChange(of: tabManager.isWorkspaceCycleHot) { _ in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.view.hotChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)"
                )
            } else {
                dlog("ws.view.hotChange id=none hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)")
            }
#endif
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onChange(of: retiringWorkspaceId) { _ in
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(tabManager.$pendingBackgroundWorkspaceLoadIds) { _ in
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(tabManager.$debugPinnedWorkspaceLoadIds) { _ in
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidSetTitle)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
            sidebarSelectionState.selection = .tabs
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "focus")
            attemptCommandPaletteFocusRestoreIfNeeded()
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onChange(of: titlebarThemeGeneration) { oldValue, newValue in
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh applied oldGeneration=\(oldValue) generation=\(newValue) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidBecomeFirstResponderSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedPanelId = selectedWorkspace.focusedPanelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: focusedPanelId),
                  focusedBrowser.webView === webView else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  selectedWorkspace.focusedPanelId == panelId,
                  selectedWorkspace.browserPanel(for: panelId) != nil else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_address_bar")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )) { _ in
            attemptCommandPaletteFocusRestoreIfNeeded()
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { notification in
            guard commandPalettePendingTextSelectionBehavior != nil else { return }
            guard let editor = notification.object as? NSTextView,
                  editor.isFieldEditor else { return }
            guard let observedWindow else { return }
            guard editor.window === observedWindow else { return }
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onChange(of: isCommandPaletteSearchFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        view = AnyView(view.onChange(of: isCommandPaletteRenameFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        view = AnyView(view.onReceive(tabManager.$tabs) { tabs in
            let existingIds = Set(tabs.map { $0.id })
            if let retiringWorkspaceId, !existingIds.contains(retiringWorkspaceId) {
                self.retiringWorkspaceId = nil
                workspaceHandoffFallbackTask?.cancel()
                workspaceHandoffFallbackTask = nil
            }
            if let previousSelectedWorkspaceId, !existingIds.contains(previousSelectedWorkspaceId) {
                self.previousSelectedWorkspaceId = tabManager.selectedTabId
            }
            tabManager.pruneBackgroundWorkspaceLoads(existingIds: existingIds)
            reconcileMountedWorkspaceIds(tabs: tabs)
            selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
            }
            if let lastIndex = lastSidebarSelectionIndex, lastIndex >= tabs.count {
                if let selectedId = tabManager.selectedTabId {
                    lastSidebarSelectionIndex = tabs.firstIndex { $0.id == selectedId }
                } else {
                    lastSidebarSelectionIndex = nil
                }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(tabs: tabs)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.stateDidChange)) { notification in
            let tabId = SidebarDragLifecycleNotification.tabId(from: notification)
            sidebarDraggedTabId = tabId
#if DEBUG
            dlog(
                "sidebar.dragState.content tab=\(debugShortWorkspaceId(tabId)) " +
                "reason=\(SidebarDragLifecycleNotification.reason(from: notification))"
            )
#endif
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteToggleRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            toggleCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteCommands()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSwitcherRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteSwitcher()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSubmitRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            handleCommandPaletteSubmitRequest()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteDismissRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            dismissCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameTabRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteRenameTabInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameWorkspaceRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteRenameWorkspaceInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteEditWorkspaceDescriptionRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            let shouldHandle = Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            )
#if DEBUG
            dlog(
                "palette.wsDescription.request observed={\(debugCommandPaletteWindowSummary(observedWindow))} " +
                "requested={\(debugCommandPaletteWindowSummary(requestedWindow))} " +
                "shouldHandle=\(shouldHandle ? 1 : 0) presented=\(isCommandPalettePresented ? 1 : 0) " +
                "mode=\(debugCommandPaletteModeLabel(commandPaletteMode))"
            )
#endif
            guard shouldHandle else { return }
            openCommandPaletteWorkspaceDescriptionInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteMoveSelection)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .commands = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
            moveCommandPaletteSelection(by: delta)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputInteractionRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            handleCommandPaletteRenameInputInteraction()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputDeleteBackwardRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            _ = handleCommandPaletteRenameDeleteBackward(modifiers: [])
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .feedbackComposerRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            presentFeedbackComposer()
        })

        view = AnyView(view.background(WindowAccessor(dedupeByWindow: false) { window in
            MainActor.assumeIsolated {
                let tmuxOverlayController = tmuxWorkspacePaneWindowOverlayController(for: window)
                tmuxOverlayController.update(state: tmuxWorkspacePaneWindowOverlayState(for: window))
                let overlayController = commandPaletteWindowOverlayController(for: window)
                overlayController.update(rootView: AnyView(commandPaletteOverlay), isVisible: isCommandPalettePresented)
            }
        }))

        view = AnyView(view.onChange(of: bgGlassTintHex) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onChange(of: bgGlassTintOpacity) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = true
            setTitlebarControlsHidden(true, in: window)
            AppDelegate.shared?.fullscreenControlsViewModel = fullscreenControlsViewModel
            syncTrafficLightInset()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = false
            setTitlebarControlsHidden(false, in: window)
            AppDelegate.shared?.fullscreenControlsViewModel = nil
            syncTrafficLightInset()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            clampSidebarWidthIfNeeded(availableWidth: window.contentView?.bounds.width ?? window.contentLayoutRect.width)
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarWidth) { _ in
            let sanitized = normalizedSidebarWidth(sidebarWidth)
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
                return
            }
            if abs(sidebarState.persistedWidth - sanitized) > 0.5 {
                sidebarState.persistedWidth = sanitized
            }
            // Sidebar width changes are pure SwiftUI layout updates, so portal-hosted
            // terminals need an explicit post-layout geometry resync.
            if let observedWindow {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
            } else {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            }
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarState.isVisible) { _ in
            if let observedWindow {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
            } else {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            }
            updateSidebarResizerBandState()
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: sidebarMatchTerminalBackground) { _ in
            guard sidebarState.isVisible,
                  sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue else { return }
            if let observedWindow {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
            } else {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            }
        })

        view = AnyView(view.onChange(of: isMinimalMode) { _, _ in
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: tabManager.tabs.map(\.id)) { _ in
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: sidebarState.persistedWidth) { newValue in
            let sanitized = normalizedSidebarWidth(newValue)
            if abs(newValue - sanitized) > 0.5 {
                sidebarState.persistedWidth = sanitized
                return
            }
            guard !isResizerDragging else { return }
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
            }
        })

        view = AnyView(view.ignoresSafeArea())
        view = AnyView(view.sheet(isPresented: $isFeedbackComposerPresented) {
            SidebarFeedbackComposerSheet()
        })

        view = AnyView(view.onDisappear {
            if isResizerDragging {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                isResizerDragging = false
                sidebarDragStartWidth = nil
            }
            removeSidebarResizerPointerMonitor()
        })

        view = AnyView(view.background(WindowAccessor { [sidebarBlendMode, bgGlassEnabled, bgGlassTintHex, bgGlassTintOpacity] window in
            window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
            window.titlebarAppearsTransparent = true
            // Keep window immovable; the sidebar's WindowDragHandleView handles
            // drag-to-move via performDrag with temporary movable override.
            // isMovableByWindowBackground=true breaks tab reordering, and
            // isMovable=true blocks clicks on sidebar buttons in minimal mode.
            window.isMovableByWindowBackground = false
            window.isMovable = false
            window.styleMask.insert(.fullSizeContentView)

            // Track this window for fullscreen notifications
            if observedWindow !== window {
                DispatchQueue.main.async {
                    observedWindow = window
                    isFullScreen = window.styleMask.contains(.fullScreen)
                    clampSidebarWidthIfNeeded(availableWidth: window.contentView?.bounds.width ?? window.contentLayoutRect.width)
                    syncCommandPaletteDebugStateForObservedWindow()
                    installSidebarResizerPointerMonitorIfNeeded()
                    updateSidebarResizerBandState()
                }
            }

            // Keep content below the titlebar so drags on Bonsplit's tab bar don't
            // get interpreted as window drags.
            let computedTitlebarHeight = window.frame.height - window.contentLayoutRect.height
            let nextPadding = max(28, min(72, computedTitlebarHeight))
            let nextSafeAreaTop = max(0, window.contentView?.safeAreaInsets.top ?? 0)
            if abs(titlebarPadding - nextPadding) > 0.5 {
                DispatchQueue.main.async {
                    titlebarPadding = nextPadding
                }
            }
            if abs(hostingSafeAreaTop - nextSafeAreaTop) > 0.5 {
                DispatchQueue.main.async {
                    hostingSafeAreaTop = nextSafeAreaTop
                }
            }
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1" {
                UpdateLogStore.shared.append("ui test window accessor: id=\(windowIdentifier) visible=\(window.isVisible)")
            }
#endif
            // User settings decide whether window glass is active. The native Tahoe
            // NSGlassEffectView path vs the older NSVisualEffectView fallback is chosen
            // inside WindowGlassEffect.apply.
            let currentThemeBackground = GhosttyBackgroundTheme.currentColor()
            let shouldApplyWindowGlass = cmuxShouldApplyWindowGlass(
                sidebarBlendMode: sidebarBlendMode,
                bgGlassEnabled: bgGlassEnabled,
                glassEffectAvailable: WindowGlassEffect.isAvailable
            )
            let shouldForceTransparentHosting =
                shouldApplyWindowGlass || currentThemeBackground.alphaComponent < 0.999

            if shouldForceTransparentHosting {
                window.isOpaque = false
                // Keep the window clear whenever translucency is active. Relying only on
                // terminal focus-driven updates can leave stale opaque window fills.
                window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
                // Configure contentView hierarchy for transparency.
                if let contentView = window.contentView {
                    makeViewHierarchyTransparent(contentView)
                }
            } else {
                // Browser-focused workspaces may not have an active terminal panel to refresh
                // the NSWindow background. Keep opaque theme changes applied here as well.
                window.backgroundColor = currentThemeBackground
                window.isOpaque = currentThemeBackground.alphaComponent >= 0.999
            }

            if shouldApplyWindowGlass {
                // Apply liquid glass effect to the window with tint from settings
                let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
                WindowGlassEffect.apply(to: window, tintColor: tintColor)
            } else {
                WindowGlassEffect.remove(from: window)
            }
            AppDelegate.shared?.attachUpdateAccessory(to: window)
            AppDelegate.shared?.applyWindowDecorations(to: window)
            AppDelegate.shared?.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState
            )
            installFileDropOverlayWhenReady(on: window, tabManager: tabManager)
        }))

        return view
    }

    private func reconcileMountedWorkspaceIds(tabs: [Workspace]? = nil, selectedId: UUID? = nil) {
        let currentTabs = tabs ?? tabManager.tabs
        let orderedTabIds = currentTabs.map { $0.id }
        let effectiveSelectedId = selectedId ?? tabManager.selectedTabId
        let handoffPinnedIds = retiringWorkspaceId.map { Set([ $0 ]) } ?? []
        let pinnedIds = handoffPinnedIds
            .union(tabManager.pendingBackgroundWorkspaceLoadIds)
            .union(tabManager.debugPinnedWorkspaceLoadIds)
        let isCycleHot = tabManager.isWorkspaceCycleHot
        let shouldKeepHandoffPair = isCycleHot && !handoffPinnedIds.isEmpty
        let baseMaxMounted = shouldKeepHandoffPair
            ? WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
            : WorkspaceMountPolicy.maxMountedWorkspaces
        let selectedCount = effectiveSelectedId == nil ? 0 : 1
        let maxMounted = max(baseMaxMounted, selectedCount + pinnedIds.count)
        let previousMountedIds = mountedWorkspaceIds
        mountedWorkspaceIds = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: mountedWorkspaceIds,
            selected: effectiveSelectedId,
            pinnedIds: pinnedIds,
            orderedTabIds: orderedTabIds,
            isCycleHot: isCycleHot,
            maxMounted: maxMounted
        )
#if DEBUG
        if mountedWorkspaceIds != previousMountedIds {
            let added = mountedWorkspaceIds.filter { !previousMountedIds.contains($0) }
            let removed = previousMountedIds.filter { !mountedWorkspaceIds.contains($0) }
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.mount.reconcile id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(isCycleHot ? 1 : 0) " +
                    "selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds)) " +
                    "added=\(debugShortWorkspaceIds(added)) removed=\(debugShortWorkspaceIds(removed))"
                )
            } else {
                dlog(
                    "ws.mount.reconcile id=none hot=\(isCycleHot ? 1 : 0) selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds))"
                )
            }
        }
#endif
    }

    private enum BackgroundWorkspacePrimeState {
        case pending
        case completed(reason: String)
    }

    private enum BackgroundWorkspacePrimePolicy {
        static let timeoutSeconds: TimeInterval = 2.0
    }

    private func primeBackgroundWorkspaceIfNeeded(workspaceId: UUID) async {
        let shouldPrime = await MainActor.run {
            tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId)
        }
        guard shouldPrime else { return }

#if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        dlog("workspace.backgroundPrime.start workspace=\(workspaceId.uuidString.prefix(5))")
#endif

        let initialState = await MainActor.run {
            stepBackgroundWorkspacePrime(workspaceId: workspaceId)
        }
        let completionReason: String
        switch initialState {
        case .completed(let reason):
            completionReason = reason
        case .pending:
            completionReason = await waitForBackgroundWorkspacePrimeCompletion(
                workspaceId: workspaceId,
                timeoutSeconds: BackgroundWorkspacePrimePolicy.timeoutSeconds
            )
        }
#if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        dlog(
            "workspace.backgroundPrime.finish workspace=\(workspaceId.uuidString.prefix(5)) " +
            "reason=\(completionReason) ms=\(String(format: "%.2f", elapsedMs))"
        )
#endif
    }

    @MainActor
    private func stepBackgroundWorkspacePrime(workspaceId: UUID) -> BackgroundWorkspacePrimeState {
        guard tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else {
            return .completed(reason: "already_cleared")
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: "workspace_removed")
        }

        workspace.requestBackgroundTerminalSurfaceStartIfNeeded()
        guard workspace.hasLoadedTerminalSurface() else {
            return .pending
        }

        tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
        return .completed(reason: "surface_ready")
    }

    @MainActor
    private func waitForBackgroundWorkspacePrimeCompletion(
        workspaceId: UUID,
        timeoutSeconds: TimeInterval
    ) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var resolved = false
            var workspacePanelsCancellable: AnyCancellable?
            var pendingLoadsCancellable: AnyCancellable?
            var tabsCancellable: AnyCancellable?
            var readyObserver: NSObjectProtocol?
            var hostedViewObserver: NSObjectProtocol?
            var timeoutWorkItem: DispatchWorkItem?

            @MainActor
            func finish(_ reason: String) {
                guard !resolved else { return }
                resolved = true
                workspacePanelsCancellable?.cancel()
                pendingLoadsCancellable?.cancel()
                tabsCancellable?.cancel()
                if let readyObserver {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if let hostedViewObserver {
                    NotificationCenter.default.removeObserver(hostedViewObserver)
                }
                timeoutWorkItem?.cancel()
                continuation.resume(returning: reason)
            }

            @MainActor
            func evaluate() {
                switch stepBackgroundWorkspacePrime(workspaceId: workspaceId) {
                case .pending:
                    break
                case .completed(let reason):
                    finish(reason)
                }
            }

            if let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) {
                workspacePanelsCancellable = workspace.$panels
                    .map { _ in () }
                    .sink { _ in
                        Task { @MainActor in
                            evaluate()
                        }
                    }
            }

            pendingLoadsCancellable = tabManager.$pendingBackgroundWorkspaceLoadIds
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }

            tabsCancellable = tabManager.$tabs
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }

            readyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { notification in
                guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                      readyWorkspaceId == workspaceId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            hostedViewObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { notification in
                guard let hostedWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                      hostedWorkspaceId == workspaceId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            let timeoutWork = DispatchWorkItem {
                Task { @MainActor in
                    if tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) {
                        tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
                    }
                    finish("timeout")
                }
            }
            timeoutWorkItem = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

            Task { @MainActor in
                evaluate()
            }
        }
    }

    private func addTab() {
        tabManager.addTab()
        sidebarSelectionState.selection = .tabs
    }

    private func makeViewHierarchyTransparent(_ root: NSView) {
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.isOpaque = false
            stack.append(contentsOf: view.subviews)
        }
    }

    private func updateWindowGlassTint() {
        // Find this view's main window by identifier (keyWindow might be a debug panel/settings).
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowIdentifier }) else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        WindowGlassEffect.updateTint(to: window, color: tintColor)
    }

    private func setTitlebarControlsHidden(_ hidden: Bool, in window: NSWindow) {
        let controlsId = NSUserInterfaceItemIdentifier("cmux.titlebarControls")
        for accessory in window.titlebarAccessoryViewControllers {
            if accessory.view.identifier == controlsId {
                accessory.isHidden = hidden
                accessory.view.alphaValue = hidden ? 0 : 1
            }
        }
    }

    private func startWorkspaceHandoffIfNeeded(newSelectedId: UUID?) {
        let oldSelectedId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedId

        guard let oldSelectedId, let newSelectedId, oldSelectedId != newSelectedId else {
            tabManager.completePendingWorkspaceUnfocus(reason: "no_handoff")
            retiringWorkspaceId = nil
            workspaceHandoffFallbackTask?.cancel()
            workspaceHandoffFallbackTask = nil
            return
        }

        workspaceHandoffGeneration &+= 1
        let generation = workspaceHandoffGeneration
        retiringWorkspaceId = oldSelectedId
        workspaceHandoffFallbackTask?.cancel()

#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.start id=\(snapshot.id) dt=\(debugMsText(dtMs)) old=\(debugShortWorkspaceId(oldSelectedId)) " +
                "new=\(debugShortWorkspaceId(newSelectedId))"
            )
        } else {
            dlog(
                "ws.handoff.start id=none old=\(debugShortWorkspaceId(oldSelectedId)) new=\(debugShortWorkspaceId(newSelectedId))"
            )
        }
#endif

        if canCompleteWorkspaceHandoffImmediately(for: newSelectedId) {
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.handoff.fastReady id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newSelectedId))"
                )
            } else {
                dlog("ws.handoff.fastReady id=none selected=\(debugShortWorkspaceId(newSelectedId))")
            }
#endif
            completeWorkspaceHandoff(reason: "ready")
            return
        }

        workspaceHandoffFallbackTask = Task { [generation] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await MainActor.run {
                guard workspaceHandoffGeneration == generation else { return }
                completeWorkspaceHandoff(reason: "timeout")
            }
        }
    }

    private func completeWorkspaceHandoffIfNeeded(focusedTabId: UUID, reason: String) {
        guard focusedTabId == tabManager.selectedTabId else { return }
        guard retiringWorkspaceId != nil else { return }
        completeWorkspaceHandoff(reason: reason)
    }

    private func canCompleteWorkspaceHandoffImmediately(for workspaceId: UUID) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return true }
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.browserPanel(for: focusedPanelId) != nil {
            return true
        }
        return workspace.hasLoadedTerminalSurface()
    }

    private func completeWorkspaceHandoff(reason: String) {
        workspaceHandoffFallbackTask?.cancel()
        workspaceHandoffFallbackTask = nil
        let retiring = retiringWorkspaceId

        // Hide portal-hosted views for the retiring workspace BEFORE clearing
        // retiringWorkspaceId. Once cleared, reconcileMountedWorkspaceIds unmounts
        // the workspace — but dismantleNSView intentionally doesn't hide portal views
        // during transient rebuilds. Hiding here prevents stale terminal/browser
        // portals from covering the newly selected workspace.
        if let retiring, let workspace = tabManager.tabs.first(where: { $0.id == retiring }) {
            workspace.hideAllTerminalPortalViews()
            workspace.hideAllBrowserPortalViews()
        }

        retiringWorkspaceId = nil
        tabManager.completePendingWorkspaceUnfocus(reason: reason)
#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.complete id=\(snapshot.id) dt=\(debugMsText(dtMs)) reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))"
            )
        } else {
            dlog("ws.handoff.complete id=none reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))")
        }
#endif
    }

    private var commandPaletteOverlay: some View {
        GeometryReader { proxy in
            let maxAllowedWidth = max(340, proxy.size.width - 260)
            let targetWidth = min(560, maxAllowedWidth)
            let workspaceDescriptionMaxEditorHeight = max(
                CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight,
                proxy.size.height - 120
            )

            ZStack(alignment: .top) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handleCommandPaletteBackdropClick(atContentPoint: value.location)
                            }
                    )

                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("CommandPaletteBackdrop")

                VStack(spacing: 0) {
                    switch commandPaletteMode {
                    case .commands:
                        commandPaletteCommandListView
                    case .renameInput(let target):
                        commandPaletteRenameInputView(target: target)
                    case let .renameConfirm(target, proposedName):
                        commandPaletteRenameConfirmView(target: target, proposedName: proposedName)
                    case .workspaceDescriptionInput(let target):
                        commandPaletteWorkspaceDescriptionInputView(
                            target: target,
                            maxEditorHeight: workspaceDescriptionMaxEditorHeight
                        )
                    }
                }
                .frame(width: targetWidth)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 5)
                .padding(.top, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand {
            dismissCommandPalette()
        }
        .zIndex(2000)
    }

    private var commandPaletteCommandListView: some View {
        let visibleResults = commandPaletteVisibleResults
        let selectedIndex = commandPaletteSelectedIndex(resultCount: visibleResults.count)
        let commandPaletteListIdentity = "\(commandPaletteListScope.rawValue):\(commandPaletteQuery)"
        let commandPaletteListMaxHeight: CGFloat = 450
        let commandPaletteRowHeight: CGFloat = 24
        let commandPaletteEmptyStateHeight: CGFloat = 44
        let commandPaletteListContentHeight = visibleResults.isEmpty
            ? commandPaletteEmptyStateHeight
            : CGFloat(visibleResults.count) * commandPaletteRowHeight
        let commandPaletteListHeight = min(commandPaletteListMaxHeight, commandPaletteListContentHeight)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                CommandPaletteSearchFieldRepresentable(
                    placeholder: commandPaletteSearchPlaceholder,
                    text: $commandPaletteQuery,
                    isFocused: Binding(
                        get: { isCommandPaletteSearchFocused },
                        set: { isCommandPaletteSearchFocused = $0 }
                    ),
                    onSubmit: runSelectedCommandPaletteResult,
                    onEscape: { dismissCommandPalette() },
                    onMoveSelection: moveCommandPaletteSelection(by:)
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            ScrollView {
                // Rebuild the full results container on scope/query transitions so
                // stale switcher rows cannot linger above command-mode results.
                VStack(spacing: 0) {
                    if visibleResults.isEmpty {
                        if commandPaletteShouldShowEmptyState {
                            Text(commandPaletteEmptyStateText)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: commandPaletteEmptyStateHeight)
                        }
                    } else {
                        ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
                            let isSelected = index == selectedIndex
                            let isHovered = commandPaletteHoveredResultIndex == index
                            let trailingLabel = commandPaletteTrailingLabel(for: result.command)
                            let rowBackground: Color = isSelected
                                ? cmuxAccentColor().opacity(0.12)
                                : (isHovered ? Color.primary.opacity(0.08) : .clear)

                            Button {
                                runCommandPaletteResult(commandID: result.id)
                            } label: {
                                Self.commandPaletteResultLabelContent(
                                    title: result.command.title,
                                    matchedIndices: result.titleMatchIndices,
                                    trailingLabel: trailingLabel
                                )
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(rowBackground)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("CommandPaletteResultRow.\(index)")
                            .accessibilityValue(result.id)
                            .id(index)
                            .onHover { hovering in
                                if hovering {
                                    commandPaletteHoveredResultIndex = index
                                } else if commandPaletteHoveredResultIndex == index {
                                    commandPaletteHoveredResultIndex = nil
                                }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .id(commandPaletteListIdentity)
            .frame(height: commandPaletteListHeight)
            .scrollPosition(
                id: Binding(
                    get: { commandPaletteScrollTargetIndex },
                    // Ignore passive readback so manual scrolling doesn't mutate selection-follow state.
                    set: { _ in }
                ),
                anchor: commandPaletteScrollTargetAnchor
            )
            .onChange(of: commandPaletteSelectedResultIndex) { _ in
                updateCommandPaletteScrollTarget(resultCount: visibleResults.count, animated: true)
            }

            // Keep Esc-to-close behavior without showing footer controls.
            Button(action: { dismissCommandPalette() }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            commandPaletteHoveredResultIndex = nil
            updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
            resetCommandPaletteSearchFocus()
        }
        .onChange(of: commandPaletteQuery) { oldValue, newValue in
            commandPaletteSelectedResultIndex = 0
            commandPaletteSelectionAnchorCommandID = nil
            commandPaletteHoveredResultIndex = nil
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            if Self.commandPaletteShouldResetVisibleResultsForQueryTransition(
                oldQuery: oldValue,
                newQuery: newValue,
                hasVisibleResults: commandPaletteVisibleResultsScope != nil
            ) {
                cachedCommandPaletteResults = []
                commandPaletteVisibleResults = []
                commandPaletteVisibleResultsScope = nil
                commandPaletteVisibleResultsFingerprint = nil
            }
            scheduleCommandPaletteResultsRefresh(query: newValue)
            updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteCurrentSearchFingerprint) { _ in
            Task { @MainActor in
                // Let the query-state transition settle first so the forced corpus refresh
                // cannot rebuild the old command list after deleting the ">" prefix.
                await Task.yield()
                scheduleCommandPaletteResultsRefresh(
                    query: commandPaletteQuery,
                    forceSearchCorpusRefresh: true
                )
                updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
                syncCommandPaletteDebugStateForObservedWindow()
            }
        }
        .onChange(of: commandPaletteResultsRevision) { _ in
            let resultIDs = cachedCommandPaletteResults.map(\.id)
            commandPaletteSelectedResultIndex = Self.commandPaletteResolvedSelectionIndex(
                preferredCommandID: commandPaletteSelectionAnchorCommandID,
                fallbackSelectedIndex: commandPaletteSelectedResultIndex,
                resultIDs: resultIDs
            )
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            let visibleResultCount = commandPaletteVisibleResults.count
            updateCommandPaletteScrollTarget(resultCount: visibleResultCount, animated: false)
            if let hoveredIndex = commandPaletteHoveredResultIndex, hoveredIndex >= visibleResultCount {
                commandPaletteHoveredResultIndex = nil
            }
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteSelectedResultIndex) { _ in
            syncCommandPaletteDebugStateForObservedWindow()
        }
    }

    private enum CommandPaletteEditorFieldStyle {
        case singleLine(
            accessibilityIdentifier: String,
            focus: FocusState<Bool>.Binding,
            onDeleteBackward: ((EventModifiers) -> BackportKeyPressResult)?
        )
        case multiline(
            accessibilityIdentifier: String,
            accessibilityLabel: String,
            focus: Binding<Bool>,
            measuredHeight: Binding<CGFloat>,
            maxHeight: CGFloat
        )
    }

    @ViewBuilder
    private func commandPaletteEditorField(
        style: CommandPaletteEditorFieldStyle,
        placeholder: String,
        text: Binding<String>,
        onSubmit: @escaping (String) -> Void,
        onEscape: @escaping () -> Void,
        onInteraction: (() -> Void)? = nil
    ) -> some View {
        switch style {
        case .singleLine(let accessibilityIdentifier, let focus, let onDeleteBackward):
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .tint(Color(nsColor: sidebarActiveForegroundNSColor(opacity: 1.0)))
                .focused(focus)
                .accessibilityIdentifier(accessibilityIdentifier)
                .backport.onKeyPress(.delete) { modifiers in
                    onDeleteBackward?(modifiers) ?? .ignored
                }
                .onSubmit {
                    onSubmit(text.wrappedValue)
                }
                .onTapGesture {
                    onInteraction?()
                }
        case .multiline(let accessibilityIdentifier, let accessibilityLabel, let focus, let measuredHeight, let maxHeight):
            CommandPaletteMultilineTextEditorRepresentable(
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                text: text,
                isFocused: focus,
                measuredHeight: measuredHeight,
                maxHeight: maxHeight,
                onSubmit: onSubmit,
                onEscape: onEscape
            )
            .frame(height: measuredHeight.wrappedValue)
        }
    }

    private func commandPaletteRenameInputView(target: CommandPaletteRenameTarget) -> some View {
        VStack(spacing: 0) {
            commandPaletteEditorField(
                style: .singleLine(
                    accessibilityIdentifier: "CommandPaletteRenameField",
                    focus: $isCommandPaletteRenameFocused,
                    onDeleteBackward: handleCommandPaletteRenameDeleteBackward(modifiers:)
                ),
                placeholder: target.placeholder,
                text: $commandPaletteRenameDraft,
                onSubmit: { _ in continueRenameFlow(target: target) },
                onEscape: { dismissCommandPalette() },
                onInteraction: handleCommandPaletteRenameInputInteraction
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            Text(renameInputHintText(target: target))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                continueRenameFlow(target: target)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            resetCommandPaletteRenameFocus()
        }
    }

    private func commandPaletteRenameConfirmView(
        target: CommandPaletteRenameTarget,
        proposedName: String
    ) -> some View {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmedName.isEmpty ? String(localized: "commandPalette.rename.clearCustomName", defaultValue: "(clear custom name)") : trimmedName

        return VStack(spacing: 0) {
            Text(nextName)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text(renameConfirmHintText(target: target))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                applyRenameFlow(target: target, proposedName: proposedName)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func commandPaletteWorkspaceDescriptionInputView(
        target: CommandPaletteWorkspaceDescriptionTarget,
        maxEditorHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            commandPaletteEditorField(
                style: .multiline(
                    accessibilityIdentifier: "CommandPaletteWorkspaceDescriptionEditor",
                    accessibilityLabel: String(
                        localized: "command.editWorkspaceDescription.title",
                        defaultValue: "Edit Workspace Description…"
                    ),
                    focus: $commandPaletteShouldFocusWorkspaceDescriptionEditor,
                    measuredHeight: $commandPaletteWorkspaceDescriptionHeight,
                    maxHeight: maxEditorHeight
                ),
                placeholder: target.placeholder,
                text: $commandPaletteWorkspaceDescriptionDraft,
                onSubmit: { proposedDescription in
                    applyWorkspaceDescriptionFlow(target: target, proposedDescription: proposedDescription)
                },
                onEscape: { dismissCommandPalette() }
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            Text(target.inputHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
        }
        .onAppear {
#if DEBUG
            dlog(
                "palette.wsDescription.view.appear workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "draftLen=\((commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "height=\(String(format: "%.1f", commandPaletteWorkspaceDescriptionHeight)) " +
                "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
            )
#endif
            resetCommandPaletteWorkspaceDescriptionFocus()
        }
        .onChange(of: commandPaletteShouldFocusWorkspaceDescriptionEditor) { _, newValue in
#if DEBUG
            dlog(
                "palette.wsDescription.focus.binding new=\(newValue ? 1 : 0) " +
                "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
        }
    }

    private final class CommandPaletteNativeTextField: NSTextField {
        var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            usesSingleLineMode = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func keyDown(with event: NSEvent) {
            if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
                super.keyDown(with: event)
                return
            }
            if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
                return super.performKeyEquivalent(with: event)
            }
            if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    // Keep navigation on the AppKit field editor so deleting the ">" prefix
    // cannot drop the palette's arrow-key handlers during the scope switch.
    private struct CommandPaletteSearchFieldRepresentable: NSViewRepresentable {
        let placeholder: String
        @Binding var text: String
        @Binding var isFocused: Bool
        let onSubmit: () -> Void
        let onEscape: () -> Void
        let onMoveSelection: (Int) -> Void

        final class Coordinator: NSObject, NSTextFieldDelegate {
            var parent: CommandPaletteSearchFieldRepresentable
            var isProgrammaticMutation = false
            weak var parentField: CommandPaletteNativeTextField?
            var pendingFocusRequest: Bool?
            var editorTextDidChangeObserver: NSObjectProtocol?
            weak var observedEditor: NSTextView?

            init(parent: CommandPaletteSearchFieldRepresentable) {
                self.parent = parent
            }

            deinit {
                detachEditorTextDidChangeObserver()
            }

            func controlTextDidChange(_ obj: Notification) {
                guard !isProgrammaticMutation else { return }
                guard let field = obj.object as? NSTextField else { return }
                parent.text = field.stringValue
            }

            func controlTextDidBeginEditing(_ obj: Notification) {
                if let field = obj.object as? NSTextField,
                   let editor = field.currentEditor() as? NSTextView {
                    attachEditorTextDidChangeObserverIfNeeded(editor)
                }
                if !parent.isFocused {
                    DispatchQueue.main.async {
                        self.parent.isFocused = true
                    }
                }
            }

            func controlTextDidEndEditing(_ obj: Notification) {
                detachEditorTextDidChangeObserver()
            }

            func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.moveDown(_:)):
                    parent.onMoveSelection(1)
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    parent.onMoveSelection(-1)
                    return true
                case #selector(NSResponder.insertNewline(_:)):
                    guard !textView.hasMarkedText() else { return false }
                    parent.onSubmit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    guard !textView.hasMarkedText() else { return false }
                    parent.onEscape()
                    return true
                default:
                    return false
                }
            }

            func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
                guard !(editor?.hasMarkedText() ?? false) else { return false }

                if let delta = commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: event.modifierFlags,
                    chars: event.characters ?? event.charactersIgnoringModifiers ?? "",
                    keyCode: event.keyCode
                ) {
                    parent.onMoveSelection(delta)
                    return true
                }

                if shouldSubmitCommandPaletteWithReturn(
                    keyCode: event.keyCode,
                    flags: event.modifierFlags,
                    mode: "single_line"
                ) {
                    parent.onSubmit()
                    return true
                }

                if event.keyCode == 53,
                   event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function, .capsLock])
                    .isEmpty {
                    parent.onEscape()
                    return true
                }

                return false
            }

            func attachEditorTextDidChangeObserverIfNeeded(_ editor: NSTextView) {
                if observedEditor !== editor {
                    detachEditorTextDidChangeObserver()
                }
                guard editorTextDidChangeObserver == nil else { return }
                observedEditor = editor
                editorTextDidChangeObserver = NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification,
                    object: editor,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, !self.isProgrammaticMutation else { return }
                    self.parent.text = editor.string
                }
            }

            func detachEditorTextDidChangeObserver() {
                if let editorTextDidChangeObserver {
                    NotificationCenter.default.removeObserver(editorTextDidChangeObserver)
                    self.editorTextDidChangeObserver = nil
                }
                observedEditor = nil
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> CommandPaletteNativeTextField {
            let field = CommandPaletteNativeTextField(frame: .zero)
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = placeholder
            field.setAccessibilityIdentifier("CommandPaletteSearchField")
            field.delegate = context.coordinator
            field.stringValue = text
            field.isEditable = true
            field.isSelectable = true
            field.isEnabled = true
            field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
                coordinator?.handleKeyEvent(event, editor: editor) ?? false
            }
            context.coordinator.parentField = field
            return field
        }

        func updateNSView(_ nsView: CommandPaletteNativeTextField, context: Context) {
            context.coordinator.parent = self
            context.coordinator.parentField = nsView
            nsView.placeholderString = placeholder

            if let editor = nsView.currentEditor() as? NSTextView {
                context.coordinator.attachEditorTextDidChangeObserverIfNeeded(editor)
                if editor.string != text, !editor.hasMarkedText() {
                    context.coordinator.isProgrammaticMutation = true
                    editor.string = text
                    nsView.stringValue = text
                    context.coordinator.isProgrammaticMutation = false
                }
            } else if nsView.stringValue != text {
                context.coordinator.detachEditorTextDidChangeObserver()
                nsView.stringValue = text
            } else {
                context.coordinator.detachEditorTextDidChangeObserver()
            }

            guard let window = nsView.window else { return }
            let firstResponder = window.firstResponder
            let isFirstResponder =
                firstResponder === nsView ||
                nsView.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView

            if isFocused, !isFirstResponder, context.coordinator.pendingFocusRequest != true {
                context.coordinator.pendingFocusRequest = true
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let coordinator, coordinator.parent.isFocused else { return }
                    guard let nsView, let window = nsView.window else { return }
                    let firstResponder = window.firstResponder
                    let alreadyFocused =
                        firstResponder === nsView ||
                        nsView.currentEditor() != nil ||
                        ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard !alreadyFocused else { return }
                    window.makeFirstResponder(nsView)
                }
            }
        }

        static func dismantleNSView(_ nsView: CommandPaletteNativeTextField, coordinator: Coordinator) {
            nsView.delegate = nil
            nsView.onHandleKeyEvent = nil
            coordinator.detachEditorTextDidChangeObserver()
            coordinator.parentField = nil
        }
    }

    private final class CommandPalettePassthroughLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class CommandPaletteMultilineTextView: NSTextView {
        var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?
        var onDidBecomeFirstResponder: (() -> Void)?

        override func flagsChanged(with event: NSEvent) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.flagsChanged " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            super.flagsChanged(with: event)
        }

        override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()
#if DEBUG
            dlog(
                "palette.wsDescription.editor.textView.becomeFirstResponder success=\(becameFirstResponder ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window?.firstResponder))"
            )
#endif
            if becameFirstResponder {
                onDidBecomeFirstResponder?()
            }
            return becameFirstResponder
        }

        override func keyDown(with event: NSEvent) {
            if hasMarkedText() {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.keyDown markedText=1 " +
                    "\(debugCommandPaletteKeyEventSummary(event))"
                )
#endif
                super.keyDown(with: event)
                return
            }
            let handled = onHandleKeyEvent?(event, self) == true
#if DEBUG
            dlog(
                "palette.wsDescription.editor.keyDown handled=\(handled ? 1 : 0) " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            if handled {
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if hasMarkedText() {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.performKeyEquivalent markedText=1 " +
                    "\(debugCommandPaletteKeyEventSummary(event))"
                )
#endif
                return super.performKeyEquivalent(with: event)
            }
            let handled = onHandleKeyEvent?(event, self) == true
#if DEBUG
            dlog(
                "palette.wsDescription.editor.performKeyEquivalent handled=\(handled ? 1 : 0) " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            if handled {
                return true
            }
            let result = super.performKeyEquivalent(with: event)
#if DEBUG
            dlog(
                "palette.wsDescription.editor.performKeyEquivalent superResult=\(result ? 1 : 0) " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            return result
        }

        override func doCommand(by commandSelector: Selector) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.doCommand selector=\(NSStringFromSelector(commandSelector)) " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.doCommand(by: commandSelector)
        }

        override func insertNewline(_ sender: Any?) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.insertNewline " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.insertNewline(sender)
        }

        override func insertLineBreak(_ sender: Any?) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.insertLineBreak " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.insertLineBreak(sender)
        }

        override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.insertNewlineIgnoringFieldEditor " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.insertNewlineIgnoringFieldEditor(sender)
        }
    }

    private final class CommandPaletteMultilineTextEditorView: NSView {
        private static let font = NSFont.systemFont(ofSize: 13)
        private static let textInset = NSSize(width: 0, height: 2)
        static let defaultMinimumHeight: CGFloat = {
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            return lineHeight * 5 + textInset.height * 2
        }()

        private let scrollView = NSScrollView(frame: .zero)
        let textView = CommandPaletteMultilineTextView(frame: .zero)
        private let placeholderField = CommandPalettePassthroughLabel(labelWithString: "")
        var onMeasuredHeightChange: ((CGFloat) -> Void)?
        private var lastReportedHeight: CGFloat?
        var maximumHeight: CGFloat = .greatestFiniteMagnitude {
            didSet {
                refreshMetrics()
            }
        }

        var placeholder: String = "" {
            didSet {
                placeholderField.stringValue = placeholder
                updatePlaceholderVisibility()
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            addSubview(scrollView)

            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.isEditable = true
            textView.isSelectable = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.backgroundColor = .clear
            textView.drawsBackground = false
            textView.font = Self.font
            textView.textColor = .labelColor
            textView.insertionPointColor = .labelColor
            textView.textContainerInset = Self.textInset
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.heightTracksTextView = false
            textView.minSize = NSSize(width: 0, height: Self.defaultMinimumHeight)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.documentView = textView

            placeholderField.translatesAutoresizingMaskIntoConstraints = false
            placeholderField.font = Self.font
            placeholderField.textColor = .secondaryLabelColor
            placeholderField.lineBreakMode = .byWordWrapping
            placeholderField.maximumNumberOfLines = 0
            addSubview(placeholderField)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textDidChange(_:)),
                name: NSText.didChangeNotification,
                object: textView
            )

            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

                placeholderField.topAnchor.constraint(equalTo: topAnchor, constant: Self.textInset.height),
                placeholderField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset.width),
                placeholderField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.textInset.width),
            ])

            updatePlaceholderVisibility()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func layout() {
            super.layout()
            updateTextViewLayout()
            reportMeasuredHeightIfNeeded()
        }

        func refreshMetrics() {
            updatePlaceholderVisibility()
            needsLayout = true
            layoutSubtreeIfNeeded()
            reportMeasuredHeightIfNeeded()
        }

        func focusIfNeeded() {
            guard let window else {
#if DEBUG
                dlog("palette.wsDescription.editor.focusIfNeeded window=nil")
#endif
                return
            }
            guard window.firstResponder !== textView else {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.focusIfNeeded alreadyFocused window={\(debugCommandPaletteWindowSummary(window))}"
                )
#endif
                return
            }
#if DEBUG
            dlog(
                "palette.wsDescription.editor.focusIfNeeded attempt window={\(debugCommandPaletteWindowSummary(window))} " +
                "frBefore=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            let didFocus = window.makeFirstResponder(textView)
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
#if DEBUG
            dlog(
                "palette.wsDescription.editor.focusIfNeeded result didFocus=\(didFocus ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "frAfter=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
        }

        private func cappedMaximumHeight() -> CGFloat {
            max(Self.defaultMinimumHeight, maximumHeight)
        }

        private func naturalHeight(for width: CGFloat) -> CGFloat {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return Self.defaultMinimumHeight
            }
            textContainer.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
            let contentHeight = max(lineHeight, ceil(usedRect.height))
            return max(
                Self.defaultMinimumHeight,
                ceil(contentHeight + Self.textInset.height * 2)
            )
        }

        private func updateTextViewLayout() {
            let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
            let naturalHeight = naturalHeight(for: availableWidth)
            let measuredHeight = min(cappedMaximumHeight(), naturalHeight)
            let documentHeight = max(naturalHeight, measuredHeight)
            textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: documentHeight)
        }

        private func fittingHeight() -> CGFloat {
            let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
            return min(cappedMaximumHeight(), naturalHeight(for: availableWidth))
        }

        private func reportMeasuredHeightIfNeeded() {
            let height = fittingHeight()
            guard lastReportedHeight == nil || abs((lastReportedHeight ?? height) - height) > 0.5 else { return }
            lastReportedHeight = height
            onMeasuredHeightChange?(height)
        }

        @objc
        private func textDidChange(_ notification: Notification) {
            updatePlaceholderVisibility()
            reportMeasuredHeightIfNeeded()
#if DEBUG
            let newlineCount = textView.string.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.editor.textDidChange len=\((textView.string as NSString).length) " +
                "newlines=\(newlineCount)"
            )
#endif
        }

        private func updatePlaceholderVisibility() {
            placeholderField.isHidden = textView.string.isEmpty == false
        }
    }

    private struct CommandPaletteMultilineTextEditorRepresentable: NSViewRepresentable {
        static let defaultMinimumHeight = CommandPaletteMultilineTextEditorView.defaultMinimumHeight

        let placeholder: String
        let accessibilityLabel: String
        let accessibilityIdentifier: String
        @Binding var text: String
        @Binding var isFocused: Bool
        @Binding var measuredHeight: CGFloat
        let maxHeight: CGFloat
        let onSubmit: (String) -> Void
        let onEscape: () -> Void

        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: CommandPaletteMultilineTextEditorRepresentable
            var isProgrammaticMutation = false
            var pendingFocusRequest = false

            init(parent: CommandPaletteMultilineTextEditorRepresentable) {
                self.parent = parent
            }

            func textDidBeginEditing(_ notification: Notification) {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.beginEditing focus=\(parent.isFocused ? 1 : 0) " +
                    "responder=\(debugCommandPaletteResponderSummary(notification.object as? NSResponder))"
                )
#endif
                if !parent.isFocused {
                    DispatchQueue.main.async {
                        self.parent.isFocused = true
                    }
                }
            }

            func textDidChange(_ notification: Notification) {
                guard !isProgrammaticMutation,
                      let textView = notification.object as? NSTextView else { return }
                parent.text = textView.string
            }

            func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.command selector=\(NSStringFromSelector(commandSelector)) " +
                    "len=\((textView.string as NSString).length) " +
                    "sel=\(textView.selectedRange().location):\(textView.selectedRange().length)"
                )
#endif
                return false
            }

            func handleDidBecomeFirstResponder() {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.didBecomeFirstResponder focus=\(parent.isFocused ? 1 : 0)"
                )
#endif
                if !parent.isFocused {
                    parent.isFocused = true
                }
            }

            func handleMeasuredHeight(_ height: CGFloat) {
                guard abs(parent.measuredHeight - height) > 0.5 else { return }
                DispatchQueue.main.async {
                    self.parent.measuredHeight = height
                }
            }

            func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
                guard !(editor?.hasMarkedText() ?? false) else { return false }

                let normalizedFlags = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function, .capsLock])

#if DEBUG
                dlog(
                    "palette.wsDescription.editor.handleKeyEvent " +
                    "\(debugCommandPaletteKeyEventSummary(event)) " +
                    "normalized=\(debugCommandPaletteModifierFlagsSummary(normalizedFlags))"
                )
#endif

                if event.keyCode == 36 || event.keyCode == 76 {
                    if normalizedFlags.isEmpty {
                        let currentText = editor?.string ?? parent.text
#if DEBUG
                        dlog("palette.wsDescription.editor.handleKeyEvent action=submit")
                        dlog(
                            "palette.wsDescription.editor.handleKeyEvent submitText " +
                            "len=\((currentText as NSString).length) " +
                            "text=\"\(debugCommandPaletteTextPreview(currentText))\""
                        )
#endif
                        if parent.text != currentText {
                            parent.text = currentText
                        }
                        parent.onSubmit(currentText)
                        return true
                    }
                    if normalizedFlags == [.shift] {
#if DEBUG
                        dlog("palette.wsDescription.editor.handleKeyEvent action=allowShiftReturn")
#endif
                        return false
                    }
                }

                if event.keyCode == 53, normalizedFlags.isEmpty {
#if DEBUG
                    dlog("palette.wsDescription.editor.handleKeyEvent action=escape")
#endif
                    parent.onEscape()
                    return true
                }

#if DEBUG
                dlog("palette.wsDescription.editor.handleKeyEvent action=passThrough")
#endif
                return false
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> CommandPaletteMultilineTextEditorView {
            let view = CommandPaletteMultilineTextEditorView(frame: .zero)
            view.placeholder = placeholder
            view.maximumHeight = maxHeight
            view.textView.string = text
            view.textView.delegate = context.coordinator
            view.textView.setAccessibilityLabel(accessibilityLabel)
            view.textView.setAccessibilityIdentifier(accessibilityIdentifier)
            view.setAccessibilityIdentifier(accessibilityIdentifier)
            view.textView.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
                coordinator?.handleKeyEvent(event, editor: editor) ?? false
            }
            view.textView.onDidBecomeFirstResponder = { [weak coordinator = context.coordinator] in
                coordinator?.handleDidBecomeFirstResponder()
            }
            view.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
                coordinator?.handleMeasuredHeight(height)
            }
            view.refreshMetrics()
#if DEBUG
            dlog(
                "palette.wsDescription.editor.make focus=\(isFocused ? 1 : 0) " +
                "textLen=\((text as NSString).length) " +
                "height=\(String(format: "%.1f", measuredHeight))"
            )
#endif
            return view
        }

        func updateNSView(_ nsView: CommandPaletteMultilineTextEditorView, context: Context) {
            context.coordinator.parent = self
            nsView.placeholder = placeholder
            nsView.maximumHeight = maxHeight
            nsView.textView.setAccessibilityLabel(accessibilityLabel)
            nsView.textView.setAccessibilityIdentifier(accessibilityIdentifier)
            nsView.setAccessibilityIdentifier(accessibilityIdentifier)

            if nsView.textView.string != text {
                context.coordinator.isProgrammaticMutation = true
                nsView.textView.string = text
                context.coordinator.isProgrammaticMutation = false
            }
            nsView.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
                coordinator?.handleMeasuredHeight(height)
            }
            nsView.refreshMetrics()

            guard let window = nsView.window else {
#if DEBUG
                if isFocused {
                    dlog(
                        "palette.wsDescription.editor.update waitingForWindow focus=1 " +
                        "pending=\(context.coordinator.pendingFocusRequest ? 1 : 0)"
                    )
                }
#endif
                return
            }
            let isFirstResponder = window.firstResponder === nsView.textView
#if DEBUG
            if isFocused || context.coordinator.pendingFocusRequest {
                dlog(
                    "palette.wsDescription.editor.update focus=\(isFocused ? 1 : 0) " +
                    "isFirstResponder=\(isFirstResponder ? 1 : 0) " +
                    "pending=\(context.coordinator.pendingFocusRequest ? 1 : 0) " +
                    "window={\(debugCommandPaletteWindowSummary(window))} " +
                    "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
                )
            }
#endif
            if isFocused, !isFirstResponder, !context.coordinator.pendingFocusRequest {
                context.coordinator.pendingFocusRequest = true
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.update scheduleFocus window={\(debugCommandPaletteWindowSummary(window))} " +
                    "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
                )
#endif
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    guard let coordinator else { return }
                    coordinator.pendingFocusRequest = false
                    guard coordinator.parent.isFocused, let nsView else { return }
                    nsView.focusIfNeeded()
                }
            }
        }

        static func dismantleNSView(_ nsView: CommandPaletteMultilineTextEditorView, coordinator: Coordinator) {
            nsView.textView.delegate = nil
            nsView.textView.onHandleKeyEvent = nil
            nsView.textView.onDidBecomeFirstResponder = nil
            nsView.onMeasuredHeightChange = nil
        }
    }

    private func renameInputHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceInputHint", defaultValue: "Enter a workspace name. Press Enter to rename, Escape to cancel.")
        case .tab:
            return String(localized: "commandPalette.rename.tabInputHint", defaultValue: "Enter a tab name. Press Enter to rename, Escape to cancel.")
        }
    }

    private func renameConfirmHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceConfirmHint", defaultValue: "Press Enter to apply this workspace name, or Escape to cancel.")
        case .tab:
            return String(localized: "commandPalette.rename.tabConfirmHint", defaultValue: "Press Enter to apply this tab name, or Escape to cancel.")
        }
    }

    private var commandPaletteListScope: CommandPaletteListScope {
        Self.commandPaletteListScope(for: commandPaletteQuery)
    }

    private var commandPaletteCurrentSearchFingerprint: Int {
        let scope = commandPaletteListScope
        return commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries,
            commandsContext: scope == .commands ? commandPaletteCachedCommandsContext() : nil
        )
    }

    nonisolated private static func commandPaletteListScope(for query: String) -> CommandPaletteListScope {
        if query.hasPrefix(Self.commandPaletteCommandsPrefix) {
            return .commands
        }
        return .switcher
    }

    static func commandPaletteShouldResetVisibleResultsForQueryTransition(
        oldQuery: String,
        newQuery: String,
        hasVisibleResults: Bool
    ) -> Bool {
        hasVisibleResults && commandPaletteListScope(for: oldQuery) != commandPaletteListScope(for: newQuery)
    }

    private var commandPaletteSwitcherIncludesSurfaceEntries: Bool {
        Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: commandPaletteQuery
        )
    }

    private var commandPaletteSearchPlaceholder: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsPlaceholder", defaultValue: "Type a command")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherPlaceholderAllSurfaces", defaultValue: "Search workspaces and surfaces")
                : String(localized: "commandPalette.search.switcherPlaceholder", defaultValue: "Search workspaces")
        }
    }

    private var commandPaletteEmptyStateText: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsEmpty", defaultValue: "No commands match your search.")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherEmptyAllSurfaces", defaultValue: "No workspaces or surfaces match your search.")
                : String(localized: "commandPalette.search.switcherEmpty", defaultValue: "No workspaces match your search.")
        }
    }

    private var commandPaletteQueryForMatching: String {
        Self.commandPaletteQueryForMatching(
            query: commandPaletteQuery,
            scope: commandPaletteListScope
        )
    }

    nonisolated private static func commandPaletteRefreshQuery(
        stateQuery: String,
        observedQuery: String?
    ) -> String {
        observedQuery ?? stateQuery
    }

    nonisolated static func commandPaletteRefreshInputsForTests(
        stateQuery: String,
        observedQuery: String?,
        searchAllSurfaces: Bool
    ) -> (scope: String, matchingQuery: String, includesSurfaces: Bool) {
        let effectiveQuery = commandPaletteRefreshQuery(
            stateQuery: stateQuery,
            observedQuery: observedQuery
        )
        let scope = commandPaletteListScope(for: effectiveQuery)
        return (
            scope: scope.rawValue,
            matchingQuery: commandPaletteQueryForMatching(query: effectiveQuery, scope: scope),
            includesSurfaces: commandPaletteSwitcherIncludesSurfaceEntries(
                searchAllSurfaces: searchAllSurfaces,
                query: effectiveQuery
            )
        )
    }

    nonisolated private static func commandPaletteQueryForMatching(
        query: String,
        scope: CommandPaletteListScope
    ) -> String {
        switch scope {
        case .commands:
            let suffix = String(query.dropFirst(Self.commandPaletteCommandsPrefix.count))
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        case .switcher:
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func commandPaletteEntries(for scope: CommandPaletteListScope) -> [CommandPaletteCommand] {
        commandPaletteEntries(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries
        )
    }

    private func commandPaletteEntries(
        for scope: CommandPaletteListScope,
        includeSurfaces: Bool,
        commandsContext: CommandPaletteCommandsContext? = nil
    ) -> [CommandPaletteCommand] {
        switch scope {
        case .commands:
            return commandPaletteCommands(commandsContext: commandsContext ?? commandPaletteCachedCommandsContext())
        case .switcher:
            return commandPaletteSwitcherEntries(includeSurfaces: includeSurfaces)
        }
    }

    nonisolated private static func commandPaletteSwitcherIncludesSurfaceEntries(
        searchAllSurfaces: Bool,
        query: String
    ) -> Bool {
        let scope = commandPaletteListScope(for: query)
        guard scope == .switcher else { return false }
        return searchAllSurfaces && !commandPaletteQueryForMatching(query: query, scope: scope).isEmpty
    }

    private func refreshCommandPaletteSearchCorpus(
        force: Bool = false,
        query: String? = nil
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let includeSurfaces = Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: effectiveQuery
        )
        let terminalOpenTargets = resolveCommandPaletteTerminalOpenTargets(for: scope)
        if commandPaletteTerminalOpenTargetAvailability != terminalOpenTargets {
            commandPaletteTerminalOpenTargetAvailability = terminalOpenTargets
        }
        let commandsContext = scope == .commands
            ? commandPaletteCommandsContext(terminalOpenTargets: terminalOpenTargets)
            : nil
        let fingerprint = commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        guard force || cachedCommandPaletteScope != scope || cachedCommandPaletteFingerprint != fingerprint else {
            return
        }

        let entries = commandPaletteEntries(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        commandPaletteSearchCommandsByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let searchCorpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        commandPaletteSearchCorpus = searchCorpus
        commandPaletteSearchCorpusByID = Dictionary(uniqueKeysWithValues: searchCorpus.map { ($0.payload, $0) })
        cachedCommandPaletteScope = scope
        cachedCommandPaletteFingerprint = fingerprint
    }

    private func cancelCommandPaletteSearch() {
        commandPaletteSearchTask?.cancel()
        commandPaletteSearchTask = nil
    }

    nonisolated private static func commandPaletteResolvedSearchMatches(
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> [CommandPaletteResolvedSearchMatch] {
        let results = CommandPaletteSearchEngine.search(
            entries: searchCorpus,
            query: query,
            historyBoost: { commandId, _ in
                Self.commandPaletteHistoryBoost(
                    for: commandId,
                    queryIsEmpty: queryIsEmpty,
                    history: usageHistory,
                    now: historyTimestamp
                )
            },
            shouldCancel: shouldCancel
        )

        return results.map { result in
            CommandPaletteResolvedSearchMatch(
                commandID: result.payload,
                score: result.score,
                titleMatchIndices: result.titleMatchIndices
            )
        }
    }

    private static func commandPaletteMaterializedSearchResults(
        matches: [CommandPaletteResolvedSearchMatch],
        commandsByID: [String: CommandPaletteCommand]
    ) -> [CommandPaletteSearchResult] {
        matches.compactMap { match in
            guard let command = commandsByID[match.commandID] else { return nil }
            return CommandPaletteSearchResult(
                command: command,
                score: match.score,
                titleMatchIndices: match.titleMatchIndices
            )
        }
    }

    private func setCommandPaletteVisibleResults(
        _ results: [CommandPaletteSearchResult],
        scope: CommandPaletteListScope,
        fingerprint: Int?
    ) {
        commandPaletteVisibleResults = results
        commandPaletteVisibleResultsScope = scope
        commandPaletteVisibleResultsFingerprint = fingerprint
    }

    private func refreshPendingCommandPaletteVisibleResults(
        scope: CommandPaletteListScope,
        fingerprint: Int?,
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval
    ) {
        let candidateCommandIDs: [String]
        if commandPaletteVisibleResultsScope == scope,
           commandPaletteVisibleResultsFingerprint == fingerprint {
            candidateCommandIDs = Self.commandPalettePreviewCandidateCommandIDs(
                resultIDs: commandPaletteVisibleResults.map(\.id),
                limit: Self.commandPaletteVisiblePreviewCandidateLimit
            )
        } else {
            candidateCommandIDs = []
        }

        let previewMatches = Self.commandPalettePreviewSearchMatches(
            scope: scope,
            searchCorpus: commandPaletteSearchCorpus,
            candidateCommandIDs: candidateCommandIDs,
            searchCorpusByID: commandPaletteSearchCorpusByID,
            query: query,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp,
            resultLimit: Self.commandPaletteVisiblePreviewResultLimit
        )
        let previewResults = Self.commandPaletteMaterializedSearchResults(
            matches: previewMatches,
            commandsByID: commandPaletteSearchCommandsByID
        )
        setCommandPaletteVisibleResults(
            previewResults,
            scope: scope,
            fingerprint: fingerprint
        )
    }

    nonisolated private static func commandPalettePreviewSearchMatches(
        scope: CommandPaletteListScope,
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        candidateCommandIDs: [String],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>],
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval,
        resultLimit: Int
    ) -> [CommandPaletteResolvedSearchMatch] {
        guard resultLimit > 0 else {
            return []
        }

        if scope == .commands {
            let matches = commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: query,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp
            )
            guard matches.count > resultLimit else {
                return matches
            }
            return Array(matches.prefix(resultLimit))
        }

        guard !candidateCommandIDs.isEmpty else {
            return []
        }

        var seenCommandIDs: Set<String> = []
        let previewEntries: [CommandPaletteSearchCorpusEntry<String>] = candidateCommandIDs.compactMap { commandID in
            guard seenCommandIDs.insert(commandID).inserted else { return nil }
            return searchCorpusByID[commandID]
        }
        guard !previewEntries.isEmpty else {
            return []
        }

        let matches = commandPaletteResolvedSearchMatches(
            searchCorpus: previewEntries,
            query: query,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp
        )
        guard matches.count > resultLimit else {
            return matches
        }
        return Array(matches.prefix(resultLimit))
    }

    nonisolated static func commandPaletteCommandPreviewMatchCommandIDsForTests(
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        candidateCommandIDs: [String],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>],
        query: String,
        resultLimit: Int
    ) -> [String] {
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        return commandPalettePreviewSearchMatches(
            scope: .commands,
            searchCorpus: searchCorpus,
            candidateCommandIDs: candidateCommandIDs,
            searchCorpusByID: searchCorpusByID,
            query: query,
            usageHistory: [:],
            queryIsEmpty: preparedQuery.isEmpty,
            historyTimestamp: 0,
            resultLimit: resultLimit
        ).map(\.commandID)
    }

    static func commandPalettePreviewCandidateCommandIDs(
        resultIDs: [String],
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        guard resultIDs.count > limit else { return resultIDs }
        return Array(resultIDs.prefix(limit))
    }

    static func commandPaletteShouldSynchronouslySeedResults(
        hasVisibleResultsForScope: Bool
    ) -> Bool {
        !hasVisibleResultsForScope
    }

    static func commandPaletteShouldPreserveEmptyStateWhileSearchPending(
        isSearchPending: Bool,
        visibleResultsScopeMatches: Bool,
        resolvedSearchScopeMatches: Bool,
        resolvedSearchFingerprintMatches: Bool,
        resolvedResultsAreEmpty: Bool,
        currentMatchingQuery: String,
        resolvedMatchingQuery: String
    ) -> Bool {
        guard isSearchPending,
              visibleResultsScopeMatches,
              resolvedSearchScopeMatches,
              resolvedSearchFingerprintMatches,
              resolvedResultsAreEmpty else {
            return false
        }

        return currentMatchingQuery == resolvedMatchingQuery
            || currentMatchingQuery.hasPrefix(resolvedMatchingQuery)
    }

    private func scheduleCommandPaletteResultsRefresh(
        query: String? = nil,
        forceSearchCorpusRefresh: Bool = false
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let matchingQuery = Self.commandPaletteQueryForMatching(
            query: effectiveQuery,
            scope: scope
        )

        refreshCommandPaletteSearchCorpus(
            force: forceSearchCorpusRefresh,
            query: effectiveQuery
        )

        commandPaletteSearchRequestID &+= 1
        let requestID = commandPaletteSearchRequestID
        let fingerprint = cachedCommandPaletteFingerprint
        let searchCorpus = commandPaletteSearchCorpus
        let commandsByID = commandPaletteSearchCommandsByID
        let usageHistory = commandPaletteUsageHistoryByCommandId
        let queryIsEmpty = CommandPaletteFuzzyMatcher.preparedQuery(matchingQuery).isEmpty
        let historyTimestamp = Date().timeIntervalSince1970
        commandPalettePendingActivation = nil
        cancelCommandPaletteSearch()
        if Self.commandPaletteShouldSynchronouslySeedResults(
            hasVisibleResultsForScope: commandPaletteVisibleResultsScope == scope
        ) {
            let matches = Self.commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp
            )
            cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                matches: matches,
                commandsByID: commandsByID
            )
            commandPaletteResolvedSearchRequestID = requestID
            commandPaletteResolvedSearchScope = scope
            commandPaletteResolvedSearchFingerprint = fingerprint
            commandPaletteResolvedMatchingQuery = matchingQuery
            isCommandPaletteSearchPending = false
            setCommandPaletteVisibleResults(
                cachedCommandPaletteResults,
                scope: scope,
                fingerprint: fingerprint
            )
            commandPaletteResultsRevision &+= 1
            return
        }
        refreshPendingCommandPaletteVisibleResults(
            scope: scope,
            fingerprint: fingerprint,
            query: matchingQuery,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp
        )
        isCommandPaletteSearchPending = true

        commandPaletteSearchTask = Task.detached(priority: .userInitiated) {
            let matches = Self.commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp,
                shouldCancel: { Task.isCancelled }
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentScope = Self.commandPaletteListScope(for: commandPaletteQuery)
                guard commandPaletteSearchRequestID == requestID,
                      isCommandPalettePresented,
                      currentScope == scope,
                      Self.commandPaletteQueryForMatching(
                          query: commandPaletteQuery,
                          scope: currentScope
                      ) == matchingQuery,
                      cachedCommandPaletteFingerprint == fingerprint else {
                    return
                }

                cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                    matches: matches,
                    commandsByID: commandPaletteSearchCommandsByID
                )
                let resultIDs = cachedCommandPaletteResults.map(\.id)
                let pendingActivation = commandPalettePendingActivation
                let resolvedActivation = Self.commandPaletteResolvedPendingActivation(
                    pendingActivation,
                    requestID: requestID,
                    resultIDs: resultIDs
                )
                commandPaletteResolvedSearchRequestID = requestID
                commandPaletteResolvedSearchScope = scope
                commandPaletteResolvedSearchFingerprint = fingerprint
                commandPaletteResolvedMatchingQuery = matchingQuery
                isCommandPaletteSearchPending = false
                setCommandPaletteVisibleResults(
                    cachedCommandPaletteResults,
                    scope: scope,
                    fingerprint: fingerprint
                )
                if Self.commandPalettePendingActivationRequestID(pendingActivation) == requestID {
                    commandPalettePendingActivation = nil
                }
                commandPaletteResultsRevision &+= 1
                if commandPaletteSearchRequestID == requestID {
                    commandPaletteSearchTask = nil
                }
                if let resolvedActivation {
                    runCommandPaletteResolvedActivation(resolvedActivation)
                }
            }
        }
    }

    private func commandPaletteEntriesFingerprint(for scope: CommandPaletteListScope) -> Int {
        commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries
        )
    }

    private func commandPaletteEntriesFingerprint(
        for scope: CommandPaletteListScope,
        includeSurfaces: Bool,
        commandsContext: CommandPaletteCommandsContext? = nil
    ) -> Int {
        switch scope {
        case .commands:
            return commandPaletteCommandsFingerprint(
                commandsContext: commandsContext ?? commandPaletteCachedCommandsContext()
            )
        case .switcher:
            return commandPaletteSwitcherEntriesFingerprint(includeSurfaces: includeSurfaces)
        }
    }

    private func commandPaletteCommandsFingerprint(commandsContext: CommandPaletteCommandsContext) -> Int {
        var hasher = Hasher()
        hasher.combine(commandsContext.snapshot.fingerprint())
        hasher.combine(cmuxConfigStore.configRevision)
        return hasher.finalize()
    }

    private func commandPaletteSwitcherEntriesFingerprint(includeSurfaces: Bool) -> Int {
        let windowContexts = commandPaletteSwitcherWindowContexts()
        let fingerprintContexts = windowContexts.map { context in
            CommandPaletteSwitcherFingerprintContext(
                windowId: context.windowId,
                windowLabel: context.windowLabel,
                selectedWorkspaceId: context.selectedWorkspaceId,
                workspaces: commandPaletteOrderedSwitcherWorkspaces(for: context).map { workspace in
                    CommandPaletteSwitcherFingerprintWorkspace(
                        id: workspace.id,
                        displayName: workspaceDisplayName(workspace),
                        metadata: commandPaletteWorkspaceSearchMetadata(for: workspace),
                        surfaces: includeSurfaces
                            ? commandPaletteOrderedSwitcherPanels(for: workspace).compactMap { panelId in
                                guard let panel = workspace.panels[panelId] else { return nil }
                                return CommandPaletteSwitcherFingerprintSurface(
                                    id: panelId,
                                    displayName: panelDisplayName(
                                        workspace: workspace,
                                        panelId: panelId,
                                        fallback: panel.displayTitle
                                    ),
                                    kindLabel: commandPaletteSurfaceKindLabel(for: panel.panelType),
                                    metadata: commandPaletteSurfaceSearchMetadata(
                                        for: workspace,
                                        panelId: panelId
                                    )
                                )
                            }
                            : []
                    )
                }
            )
        }
        return Self.commandPaletteSwitcherFingerprint(windowContexts: fingerprintContexts)
    }

    private static func commandPaletteHighlightedTitleText(_ title: String, matchedIndices: Set<Int>) -> Text {
        guard !matchedIndices.isEmpty else {
            return Text(title).foregroundColor(.primary)
        }

        let chars = Array(title)
        var index = 0
        var result = Text("")

        while index < chars.count {
            let isMatched = matchedIndices.contains(index)
            var end = index + 1
            while end < chars.count, matchedIndices.contains(end) == isMatched {
                end += 1
            }

            let segment = String(chars[index..<end])
            if isMatched {
                result = result + Text(segment).foregroundColor(.blue)
            } else {
                result = result + Text(segment).foregroundColor(.primary)
            }
            index = end
        }

        return result
    }

    @ViewBuilder
    private static func commandPaletteTrailingLabelView(_ trailingLabel: CommandPaletteTrailingLabel?) -> some View {
        if let trailingLabel {
            switch trailingLabel.style {
            case .shortcut:
                Text(trailingLabel.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            case .kind:
                Text(trailingLabel.text)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private static func commandPaletteResultLabelContent(
        title: String,
        matchedIndices: Set<Int>,
        trailingLabel: CommandPaletteTrailingLabel?
    ) -> some View {
        HStack(spacing: 8) {
            commandPaletteHighlightedTitleText(
                title,
                matchedIndices: matchedIndices
            )
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
            Spacer()
            commandPaletteTrailingLabelView(trailingLabel)
        }
    }

    private func commandPaletteTrailingLabel(for command: CommandPaletteCommand) -> CommandPaletteTrailingLabel? {
        if let shortcutHint = command.shortcutHint {
            return CommandPaletteTrailingLabel(text: shortcutHint, style: .shortcut)
        }

        if let kindLabel = command.kindLabel {
            return CommandPaletteTrailingLabel(text: kindLabel, style: .kind)
        }
        return nil
    }

    private func commandPaletteSwitcherEntries(includeSurfaces: Bool) -> [CommandPaletteCommand] {
        let windowContexts = commandPaletteSwitcherWindowContexts()
        guard !windowContexts.isEmpty else { return [] }

        var entries: [CommandPaletteCommand] = []
        let estimatedCount = windowContexts.reduce(0) { partial, context in
            let workspaceCount = context.tabManager.tabs.count
            guard includeSurfaces else { return partial + workspaceCount }
            let surfaceCount = context.tabManager.tabs.reduce(0) { count, workspace in
                count + commandPaletteOrderedSwitcherPanels(for: workspace).count
            }
            return partial + workspaceCount + surfaceCount
        }
        entries.reserveCapacity(estimatedCount)
        var nextRank = 0

        for context in windowContexts {
            let workspaces = commandPaletteOrderedSwitcherWorkspaces(for: context)
            guard !workspaces.isEmpty else { continue }

            let windowId = context.windowId
            let windowTabManager = context.tabManager
            let windowKeywords = commandPaletteWindowKeywords(windowLabel: context.windowLabel)
            for workspace in workspaces {
                let workspaceName = workspaceDisplayName(workspace)
                let workspaceCommandId = "switcher.workspace.\(workspace.id.uuidString.lowercased())"
                let workspaceKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
                    baseKeywords: [
                        "workspace",
                        "switch",
                        "go",
                        "open",
                        workspaceName
                    ] + windowKeywords,
                    metadata: commandPaletteWorkspaceSearchMetadata(for: workspace),
                    detail: .workspace
                )
                let workspaceId = workspace.id
                entries.append(
                    CommandPaletteCommand(
                        id: workspaceCommandId,
                        rank: nextRank,
                        title: workspaceName,
                        subtitle: Self.commandPaletteSwitcherSubtitle(base: String(localized: "commandPalette.switcher.workspaceLabel", defaultValue: "Workspace"), windowLabel: context.windowLabel),
                        shortcutHint: nil,
                        kindLabel: String(localized: "commandPalette.kind.workspace", defaultValue: "Workspace"),
                        keywords: workspaceKeywords,
                        dismissOnRun: true,
                        action: {
                            focusCommandPaletteSwitcherTarget(
                                windowId: windowId,
                                tabManager: windowTabManager,
                                workspaceId: workspaceId
                            )
                        }
                    )
                )
                nextRank += 1

                guard includeSurfaces else { continue }

                for panelId in commandPaletteOrderedSwitcherPanels(for: workspace) {
                    guard let panel = workspace.panels[panelId] else { continue }
                    let surfaceName = panelDisplayName(
                        workspace: workspace,
                        panelId: panelId,
                        fallback: panel.displayTitle
                    )
                    let surfaceKindLabel = commandPaletteSurfaceKindLabel(for: panel.panelType)
                    let surfaceCommandId = "switcher.surface.\(panelId.uuidString.lowercased())"
                    let surfaceKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
                        baseKeywords: [
                            "surface",
                            "tab",
                            "switch",
                            "go",
                            "open",
                            surfaceName,
                            workspaceName
                        ] + commandPaletteSurfaceKeywords(for: panel.panelType) + windowKeywords,
                        metadata: commandPaletteSurfaceSearchMetadata(for: workspace, panelId: panelId),
                        detail: .surface
                    )
                    entries.append(
                        CommandPaletteCommand(
                            id: surfaceCommandId,
                            rank: nextRank,
                            title: surfaceName,
                            subtitle: Self.commandPaletteSwitcherSubtitle(base: workspaceName, windowLabel: context.windowLabel),
                            shortcutHint: nil,
                            kindLabel: surfaceKindLabel,
                            keywords: surfaceKeywords,
                            dismissOnRun: true,
                            action: {
                                focusCommandPaletteSwitcherSurfaceTarget(
                                    windowId: windowId,
                                    tabManager: windowTabManager,
                                    workspaceId: workspace.id,
                                    panelId: panelId
                                )
                            }
                        )
                    )
                    nextRank += 1
                }
            }
        }

        return entries
    }

    private func commandPaletteSwitcherWindowContexts() -> [CommandPaletteSwitcherWindowContext] {
        let fallback = CommandPaletteSwitcherWindowContext(
            windowId: windowId,
            tabManager: tabManager,
            selectedWorkspaceId: tabManager.selectedTabId,
            windowLabel: nil
        )

        guard let appDelegate = AppDelegate.shared else { return [fallback] }
        let summaries = appDelegate.listMainWindowSummaries()
        guard !summaries.isEmpty else { return [fallback] }

        let orderedSummaries = summaries.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.windowId == windowId
            let rhsIsCurrent = rhs.windowId == windowId
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        var windowLabelById: [UUID: String] = [:]
        if orderedSummaries.count > 1 {
            for (index, summary) in orderedSummaries.enumerated() where summary.windowId != windowId {
                windowLabelById[summary.windowId] = String(localized: "commandPalette.switcher.windowLabel", defaultValue: "Window \(index + 1)")
            }
        }

        var contexts: [CommandPaletteSwitcherWindowContext] = []
        var seenWindowIds: Set<UUID> = []
        for summary in orderedSummaries {
            guard let manager = appDelegate.tabManagerFor(windowId: summary.windowId) else { continue }
            guard seenWindowIds.insert(summary.windowId).inserted else { continue }
            contexts.append(
                CommandPaletteSwitcherWindowContext(
                    windowId: summary.windowId,
                    tabManager: manager,
                    selectedWorkspaceId: summary.selectedWorkspaceId,
                    windowLabel: windowLabelById[summary.windowId]
                )
            )
        }

        if contexts.isEmpty {
            return [fallback]
        }
        return contexts
    }

    private static func commandPaletteSwitcherSubtitle(base: String, windowLabel: String?) -> String {
        guard let windowLabel else { return base }
        return "\(base) • \(windowLabel)"
    }

    private func commandPaletteWindowKeywords(windowLabel: String?) -> [String] {
        guard let windowLabel else { return [] }
        return ["window", windowLabel.lowercased()]
    }

    private func commandPaletteOrderedSwitcherWorkspaces(
        for context: CommandPaletteSwitcherWindowContext
    ) -> [Workspace] {
        var workspaces = context.tabManager.tabs
        guard !workspaces.isEmpty else { return [] }

        let selectedWorkspaceId = context.selectedWorkspaceId ?? context.tabManager.selectedTabId
        if let selectedWorkspaceId,
           let selectedIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspaceId }) {
            let selectedWorkspace = workspaces.remove(at: selectedIndex)
            workspaces.insert(selectedWorkspace, at: 0)
        }

        return workspaces
    }

    private func commandPaletteOrderedSwitcherPanels(for workspace: Workspace) -> [UUID] {
        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        guard orderedPanelIds.count < workspace.panels.count else { return orderedPanelIds }

        var panelIds = orderedPanelIds
        var seen = Set(orderedPanelIds)
        for panelId in workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where seen.insert(panelId).inserted {
            panelIds.append(panelId)
        }
        return panelIds
    }

    private func focusCommandPaletteSwitcherTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID
    ) {
        // Switcher commands dismiss the palette after action dispatch.
        // Defer focus mutation one turn so browser omnibar autofocus can run
        // without being blocked by the palette-visibility guard.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(workspaceId, suppressFlash: true)
        }
    }

    private func focusCommandPaletteSwitcherSurfaceTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID
    ) {
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(workspaceId, surfaceId: panelId, suppressFlash: true)
        }
    }

    private func commandPaletteWorkspaceSearchMetadata(for workspace: Workspace) -> CommandPaletteSwitcherSearchMetadata {
        // Keep workspace rows coarse and stable for predictable workspace switching queries.
        let directories = [workspace.currentDirectory]
        let branches = [workspace.gitBranch?.branch].compactMap { $0 }
        let ports = workspace.listeningPorts
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports,
            description: workspace.customDescription
        )
    }

    private func commandPaletteSurfaceSearchMetadata(
        for workspace: Workspace,
        panelId: UUID
    ) -> CommandPaletteSwitcherSearchMetadata {
        let directories = [workspace.panelDirectories[panelId]].compactMap { $0 }
        let branches = [workspace.panelGitBranches[panelId]?.branch].compactMap { $0 }
        let ports = workspace.surfaceListeningPorts[panelId] ?? []
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
    }

    private func commandPaletteSurfaceKindLabel(for panelType: PanelType) -> String {
        switch panelType {
        case .terminal:
            return String(localized: "commandPalette.kind.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "commandPalette.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "commandPalette.kind.markdown", defaultValue: "Markdown")
        }
    }

    private func commandPaletteSurfaceKeywords(for panelType: PanelType) -> [String] {
        switch panelType {
        case .terminal:
            return ["terminal", "shell", "console"]
        case .browser:
            return ["browser", "web", "page"]
        case .markdown:
            return ["markdown", "note", "preview"]
        }
    }

    private func commandPaletteCachedCommandsContext() -> CommandPaletteCommandsContext {
        commandPaletteCommandsContext(
            terminalOpenTargets: commandPaletteTerminalOpenTargetAvailability
        )
    }

    private func resolveCommandPaletteTerminalOpenTargets(
        for scope: CommandPaletteListScope
    ) -> Set<TerminalDirectoryOpenTarget> {
        guard scope == .commands,
              focusedPanelContext?.panel.panelType == .terminal else {
            return []
        }
        return TerminalDirectoryOpenTarget.availableTargets()
    }

    private func commandPaletteCommandsContext(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>
    ) -> CommandPaletteCommandsContext {
        let cliInstalledInPATH = AppDelegate.shared?.isCmuxCLIInstalledInPATH() ?? false
        var snapshot = commandPaletteContextSnapshot(terminalOpenTargets: terminalOpenTargets)
        snapshot.setBool(CommandPaletteContextKeys.cliInstalledInPATH, cliInstalledInPATH)
        return CommandPaletteCommandsContext(
            snapshot: snapshot
        )
    }

    private func commandPaletteCommands(
        commandsContext: CommandPaletteCommandsContext
    ) -> [CommandPaletteCommand] {
        let context = commandsContext.snapshot
        let contributions = commandPaletteCommandContributions()
        var handlerRegistry = CommandPaletteHandlerRegistry()
        registerCommandPaletteHandlers(&handlerRegistry)

        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(contributions.count)
        var nextRank = 0

        for contribution in contributions {
            guard contribution.when(context), contribution.enablement(context) else { continue }
            guard let action = handlerRegistry.handler(for: contribution.commandId) else {
                assertionFailure("No command palette handler registered for \(contribution.commandId)")
                continue
            }
            commands.append(
                CommandPaletteCommand(
                    id: contribution.commandId,
                    rank: nextRank,
                    title: contribution.title(context),
                    subtitle: contribution.subtitle(context),
                    shortcutHint: commandPaletteShortcutHint(for: contribution, context: context),
                    kindLabel: nil,
                    keywords: contribution.keywords,
                    dismissOnRun: contribution.dismissOnRun,
                    action: action
                )
            )
            nextRank += 1
        }

        return commands
    }

    private func commandPaletteShortcutHint(
        for contribution: CommandPaletteCommandContribution,
        context: CommandPaletteContextSnapshot
    ) -> String? {
        // Preserve browser reload semantics for Cmd+R when a browser tab is focused.
        if contribution.commandId == "palette.renameTab",
           context.bool(CommandPaletteContextKeys.panelIsBrowser) {
            return nil
        }
        if let action = commandPaletteShortcutAction(for: contribution.commandId) {
            return KeyboardShortcutSettings.shortcut(for: action).displayString
        }
        if let staticShortcut = commandPaletteStaticShortcutHint(for: contribution.commandId) {
            return staticShortcut
        }
        return contribution.shortcutHint
    }

    private func commandPaletteShortcutAction(for commandId: String) -> KeyboardShortcutSettings.Action? {
        switch commandId {
        case "palette.newWorkspace":
            return .newTab
        case "palette.newWindow":
            return .newWindow
        case "palette.openFolder":
            return .openFolder
        case "palette.newTerminalTab":
            return .newSurface
        case "palette.newBrowserTab":
            return .openBrowser
        case "palette.closeWindow":
            return .closeWindow
        case "palette.toggleSidebar":
            return .toggleSidebar
        case "palette.showNotifications":
            return .showNotifications
        case "palette.jumpUnread":
            return .jumpToUnread
        case "palette.renameTab":
            return .renameTab
        case "palette.renameWorkspace":
            return .renameWorkspace
        case "palette.editWorkspaceDescription":
            return .editWorkspaceDescription
        case "palette.nextWorkspace":
            return .nextSidebarTab
        case "palette.previousWorkspace":
            return .prevSidebarTab
        case "palette.nextTabInPane":
            return .nextSurface
        case "palette.previousTabInPane":
            return .prevSurface
        case "palette.browserToggleDevTools":
            return .toggleBrowserDeveloperTools
        case "palette.browserConsole":
            return .showBrowserJavaScriptConsole
        case "palette.browserReactGrab":
            return .toggleReactGrab
        case "palette.browserSplitRight", "palette.terminalSplitBrowserRight":
            return .splitBrowserRight
        case "palette.browserSplitDown", "palette.terminalSplitBrowserDown":
            return .splitBrowserDown
        case "palette.terminalSplitRight":
            return .splitRight
        case "palette.terminalSplitDown":
            return .splitDown
        case "palette.terminalFind":
            return .find
        case "palette.terminalFindNext":
            return .findNext
        case "palette.terminalFindPrevious":
            return .findPrevious
        case "palette.terminalHideFind":
            return .hideFind
        case "palette.toggleSplitZoom":
            return .toggleSplitZoom
        case "palette.triggerFlash":
            return .triggerFlash
        default:
            return nil
        }
    }

    private func commandPaletteStaticShortcutHint(for commandId: String) -> String? {
        switch commandId {
        case "palette.closeTab":
            return "⌘W"
        case "palette.closeWorkspace":
            return "⌘⇧W"
        case "palette.reopenClosedBrowserTab":
            return "⌘⇧T"
        case "palette.openSettings":
            return "⌘,"
        case "palette.browserBack":
            return "⌘["
        case "palette.browserForward":
            return "⌘]"
        case "palette.browserReload":
            return "⌘R"
        case "palette.browserFocusAddressBar":
            return "⌘L"
        case "palette.browserZoomIn":
            return "⌘="
        case "palette.browserZoomOut":
            return "⌘-"
        case "palette.browserZoomReset":
            return "⌘0"
        case "palette.terminalFind":
            return "⌘F"
        case "palette.terminalFindNext":
            return "⌘G"
        case "palette.terminalFindPrevious":
            return "⌥⌘G"
        case "palette.terminalHideFind":
            return "⌘⇧F"
        case "palette.terminalUseSelectionForFind":
            return "⌘E"
        case "palette.toggleFullScreen":
            return "\u{2303}\u{2318}F"
        default:
            return nil
        }
    }

    private func commandPaletteContextSnapshot(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>? = nil
    ) -> CommandPaletteContextSnapshot {
        var snapshot = CommandPaletteContextSnapshot()
        snapshot.setBool(CommandPaletteContextKeys.workspaceMinimalModeEnabled, isMinimalMode)

        if let workspace = tabManager.selectedWorkspace {
            snapshot.setBool(CommandPaletteContextKeys.hasWorkspace, true)
            snapshot.setString(CommandPaletteContextKeys.workspaceName, workspaceDisplayName(workspace))
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomName, workspace.customTitle != nil)
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomDescription, workspace.hasCustomDescription)
            snapshot.setBool(CommandPaletteContextKeys.workspaceShouldPin, !workspace.isPinned)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasPullRequests,
                !workspace.sidebarPullRequestsInDisplayOrder().isEmpty
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasSplits,
                workspace.bonsplitController.allPaneIds.count > 1
            )
            let workspaceIndex = tabManager.tabs.firstIndex { $0.id == workspace.id }
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasPeers, tabManager.tabs.count > 1)
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasAbove, (workspaceIndex ?? 0) > 0)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasBelow,
                (workspaceIndex ?? tabManager.tabs.count - 1) < tabManager.tabs.count - 1
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasUnread,
                notificationStore.notifications.contains { $0.tabId == workspace.id && !$0.isRead }
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasRead,
                notificationStore.notifications.contains { $0.tabId == workspace.id && $0.isRead }
            )
        }

        if let panelContext = focusedPanelContext {
            let workspace = panelContext.workspace
            let panelId = panelContext.panelId
            let panelIsTerminal = panelContext.panel.panelType == .terminal
            snapshot.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            snapshot.setString(
                CommandPaletteContextKeys.panelName,
                panelDisplayName(workspace: workspace, panelId: panelId, fallback: panelContext.panel.displayTitle)
            )
            snapshot.setBool(CommandPaletteContextKeys.panelIsBrowser, panelContext.panel.panelType == .browser)
            snapshot.setBool(CommandPaletteContextKeys.panelIsTerminal, panelIsTerminal)
            snapshot.setBool(CommandPaletteContextKeys.panelHasCustomName, workspace.panelCustomTitles[panelId] != nil)
            snapshot.setBool(CommandPaletteContextKeys.panelShouldPin, !workspace.isPanelPinned(panelId))
            let hasUnread = workspace.manualUnreadPanelIds.contains(panelId)
                || notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId)
            snapshot.setBool(CommandPaletteContextKeys.panelHasUnread, hasUnread)

            if panelIsTerminal {
                let availableTargets = terminalOpenTargets ?? TerminalDirectoryOpenTarget.availableTargets()
                for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
                    snapshot.setBool(
                        CommandPaletteContextKeys.terminalOpenTargetAvailable(target),
                        availableTargets.contains(target)
                    )
                }
            }
        }

        if case .updateAvailable = updateViewModel.effectiveState {
            snapshot.setBool(CommandPaletteContextKeys.updateHasAvailable, true)
        }

        return snapshot
    }

    private func commandPaletteCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        func workspaceSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.workspaceName) ?? String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace")
            return String(localized: "commandPalette.subtitle.workspaceWithName", defaultValue: "Workspace • \(name)")
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.tabWithName", defaultValue: "Tab • \(name)")
        }

        func browserPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.browserWithName", defaultValue: "Browser • \(name)")
        }

        func terminalPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.terminalWithName", defaultValue: "Terminal • \(name)")
        }

        var contributions: [CommandPaletteCommandContribution] = []

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                title: constant(String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")),
                subtitle: constant(String(localized: "command.newWorkspace.subtitle", defaultValue: "Workspace")),
                keywords: ["create", "new", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWindow",
                title: constant(String(localized: "command.newWindow.title", defaultValue: "New Window")),
                subtitle: constant(String(localized: "command.newWindow.subtitle", defaultValue: "Window")),
                keywords: ["create", "new", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.installCLI",
                title: constant(String(localized: "command.installCLI.title", defaultValue: "Shell Command: Install 'cmux' in PATH")),
                subtitle: constant(String(localized: "command.installCLI.subtitle", defaultValue: "CLI")),
                keywords: ["install", "cli", "path", "shell", "command", "symlink"],
                when: { !$0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.uninstallCLI",
                title: constant(String(localized: "command.uninstallCLI.title", defaultValue: "Shell Command: Uninstall 'cmux' from PATH")),
                subtitle: constant(String(localized: "command.uninstallCLI.subtitle", defaultValue: "CLI")),
                keywords: ["uninstall", "remove", "cli", "path", "shell", "command", "symlink"],
                when: { $0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolder",
                title: constant(String(localized: "command.openFolder.title", defaultValue: "Open Folder…")),
                subtitle: constant(String(localized: "command.openFolder.subtitle", defaultValue: "Workspace")),
                keywords: ["open", "folder", "repository", "project", "directory"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolderInVSCodeInline",
                title: constant(
                    String(
                        localized: "command.openFolderInVSCodeInline.title",
                        defaultValue: "Open Folder in VS Code (Inline)…"
                    )
                ),
                subtitle: constant(
                    String(
                        localized: "command.openFolderInVSCodeInline.subtitle",
                        defaultValue: "VS Code Inline"
                    )
                ),
                keywords: ["open", "folder", "directory", "project", "vs", "code", "inline", "editor", "browser"],
                when: { _ in TerminalDirectoryOpenTarget.vscodeInline.isAvailable() }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalTab",
                title: constant(String(localized: "command.newTerminalTab.title", defaultValue: "New Tab (Terminal)")),
                subtitle: constant(String(localized: "command.newTerminalTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘T",
                keywords: ["new", "terminal", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserTab",
                title: constant(String(localized: "command.newBrowserTab.title", defaultValue: "New Tab (Browser)")),
                subtitle: constant(String(localized: "command.newBrowserTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘⇧L",
                keywords: ["new", "browser", "tab", "web"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeTab",
                title: constant(String(localized: "command.closeTab.title", defaultValue: "Close Tab")),
                subtitle: constant(String(localized: "command.closeTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘W",
                keywords: ["close", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspace",
                title: constant(String(localized: "command.closeWorkspace.title", defaultValue: "Close Workspace")),
                subtitle: constant(String(localized: "command.closeWorkspace.subtitle", defaultValue: "Workspace")),
                shortcutHint: "⌘⇧W",
                keywords: ["close", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWindow",
                title: constant(String(localized: "command.closeWindow.title", defaultValue: "Close Window")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["close", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleFullScreen",
                title: constant(String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen")),
                subtitle: constant(String(localized: "command.toggleFullScreen.subtitle", defaultValue: "Window")),
                keywords: ["fullscreen", "full", "screen", "window", "toggle"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenClosedBrowserTab",
                title: constant(String(localized: "command.reopenClosedBrowserTab.title", defaultValue: "Reopen Closed Browser Tab")),
                subtitle: constant(String(localized: "command.reopenClosedBrowserTab.subtitle", defaultValue: "Browser")),
                shortcutHint: "⌘⇧T",
                keywords: ["reopen", "closed", "browser"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSidebar",
                title: constant(String(localized: "command.toggleSidebar.title", defaultValue: "Toggle Sidebar")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["toggle", "sidebar", "layout"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableMinimalMode",
                title: constant(String(localized: "command.enableMinimalMode.title", defaultValue: "Enable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { !$0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableMinimalMode",
                title: constant(String(localized: "command.disableMinimalMode.title", defaultValue: "Disable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel")),
                subtitle: constant(String(localized: "command.triggerFlash.subtitle", defaultValue: "View")),
                keywords: ["flash", "highlight", "focus", "panel"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.showNotifications",
                title: constant(String(localized: "command.showNotifications.title", defaultValue: "Show Notifications")),
                subtitle: constant(String(localized: "command.showNotifications.subtitle", defaultValue: "Notifications")),
                keywords: ["notifications", "inbox"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpUnread",
                title: constant(String(localized: "command.jumpUnread.title", defaultValue: "Jump to Latest Unread")),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["jump", "unread", "notification"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openSettings",
                title: constant(String(localized: "command.openSettings.title", defaultValue: "Open Settings")),
                subtitle: constant(String(localized: "command.openSettings.subtitle", defaultValue: "Global")),
                shortcutHint: "⌘,",
                keywords: ["settings", "preferences"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.checkForUpdates",
                title: constant(String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates")),
                subtitle: constant(String(localized: "command.checkForUpdates.subtitle", defaultValue: "Global")),
                keywords: ["update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.applyUpdateIfAvailable",
                title: constant(String(localized: "command.applyUpdateIfAvailable.title", defaultValue: "Apply Update (If Available)")),
                subtitle: constant(String(localized: "command.applyUpdateIfAvailable.subtitle", defaultValue: "Global")),
                keywords: ["apply", "install", "update", "available"],
                when: { $0.bool(CommandPaletteContextKeys.updateHasAvailable) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.attemptUpdate",
                title: constant(String(localized: "command.attemptUpdate.title", defaultValue: "Attempt Update")),
                subtitle: constant(String(localized: "command.attemptUpdate.subtitle", defaultValue: "Global")),
                keywords: ["attempt", "check", "update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.restartSocketListener",
                title: constant(String(localized: "command.restartSocketListener.title", defaultValue: "Restart CLI Listener")),
                subtitle: constant(String(localized: "command.restartSocketListener.subtitle", defaultValue: "Global")),
                keywords: ["restart", "socket", "listener", "cli", "cmux", "control"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameWorkspace",
                title: constant(String(localized: "command.renameWorkspace.title", defaultValue: "Rename Workspace…")),
                subtitle: workspaceSubtitle,
                keywords: ["rename", "workspace", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.editWorkspaceDescription",
                title: constant(String(localized: "command.editWorkspaceDescription.title", defaultValue: "Edit Workspace Description…")),
                subtitle: workspaceSubtitle,
                keywords: ["edit", "workspace", "description", "notes", "markdown"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceName",
                title: constant(String(localized: "command.clearWorkspaceName.title", defaultValue: "Clear Workspace Name")),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceDescription",
                title: constant(String(localized: "command.clearWorkspaceDescription.title", defaultValue: "Clear Workspace Description")),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "description", "notes"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomDescription)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleWorkspacePin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.workspaceShouldPin) ? String(localized: "command.pinWorkspace.title", defaultValue: "Pin Workspace") : String(localized: "command.unpinWorkspace.title", defaultValue: "Unpin Workspace")
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextWorkspace",
                title: constant(String(localized: "command.nextWorkspace.title", defaultValue: "Next Workspace")),
                subtitle: constant(String(localized: "command.nextWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["next", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousWorkspace",
                title: constant(String(localized: "command.previousWorkspace.title", defaultValue: "Previous Workspace")),
                subtitle: constant(String(localized: "command.previousWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["previous", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceUp",
                title: constant(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "up", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceDown",
                title: constant(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "down", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceToTop",
                title: constant(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "top", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeOtherWorkspaces",
                title: constant(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "other", "workspaces", "reset", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasPeers) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesBelow",
                title: constant(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "below", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesAbove",
                title: constant(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "above", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceRead",
                title: constant(String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "read", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasUnread) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceUnread",
                title: constant(String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "unread", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasRead) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameTab",
                title: constant(String(localized: "command.renameTab.title", defaultValue: "Rename Tab…")),
                subtitle: panelSubtitle,
                keywords: ["rename", "tab", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearTabName",
                title: constant(String(localized: "command.clearTabName.title", defaultValue: "Clear Tab Name")),
                subtitle: panelSubtitle,
                keywords: ["clear", "tab", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabPin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelShouldPin) ? String(localized: "command.pinTab.title", defaultValue: "Pin Tab") : String(localized: "command.unpinTab.title", defaultValue: "Unpin Tab")
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabUnread",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelHasUnread) ? String(localized: "command.markTabRead.title", defaultValue: "Mark Tab as Read") : String(localized: "command.markTabUnread.title", defaultValue: "Mark Tab as Unread")
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextTabInPane",
                title: constant(String(localized: "command.nextTabInPane.title", defaultValue: "Next Tab in Pane")),
                subtitle: constant(String(localized: "command.nextTabInPane.subtitle", defaultValue: "Tab Navigation")),
                keywords: ["next", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousTabInPane",
                title: constant(String(localized: "command.previousTabInPane.title", defaultValue: "Previous Tab in Pane")),
                subtitle: constant(String(localized: "command.previousTabInPane.subtitle", defaultValue: "Tab Navigation")),
                keywords: ["previous", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openWorkspacePullRequests",
                title: constant(String(localized: "command.openWorkspacePRLinks.title", defaultValue: "Open All Workspace PR Links")),
                subtitle: workspaceSubtitle,
                keywords: ["pull", "request", "review", "merge", "pr", "mr", "open", "links", "workspace"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    $0.bool(CommandPaletteContextKeys.workspaceHasPullRequests)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserBack",
                title: constant(String(localized: "command.browserBack.title", defaultValue: "Back")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘[",
                keywords: ["browser", "back", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserForward",
                title: constant(String(localized: "command.browserForward.title", defaultValue: "Forward")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘]",
                keywords: ["browser", "forward", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReload",
                title: constant(String(localized: "command.browserReload.title", defaultValue: "Reload Page")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘R",
                keywords: ["browser", "reload", "refresh"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserOpenDefault",
                title: constant(String(localized: "command.browserOpenDefault.title", defaultValue: "Open Current Page in Default Browser")),
                subtitle: browserPanelSubtitle,
                keywords: ["open", "default", "external", "browser"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserFocusAddressBar",
                title: constant(String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘L",
                keywords: ["browser", "address", "omnibar", "url"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserToggleDevTools",
                title: constant(String(localized: "command.browserToggleDevTools.title", defaultValue: "Toggle Developer Tools")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "devtools", "inspector"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserConsole",
                title: constant(String(localized: "command.browserConsole.title", defaultValue: "Show JavaScript Console")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "console", "javascript"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReactGrab",
                title: constant(String(localized: "command.browserReactGrab.title", defaultValue: "Toggle React Grab")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "react", "grab", "inspect", "element"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomIn",
                title: constant(String(localized: "command.browserZoomIn.title", defaultValue: "Zoom In")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "in"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomOut",
                title: constant(String(localized: "command.browserZoomOut.title", defaultValue: "Zoom Out")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "out"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomReset",
                title: constant(String(localized: "command.browserZoomReset.title", defaultValue: "Actual Size")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "reset", "actual size"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserClearHistory",
                title: constant(String(localized: "command.browserClearHistory.title", defaultValue: "Clear Browser History")),
                subtitle: constant(String(localized: "command.browserClearHistory.subtitle", defaultValue: "Browser")),
                keywords: ["browser", "history", "clear"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitRight",
                title: constant(String(localized: "command.browserSplitRight.title", defaultValue: "Split Browser Right")),
                subtitle: constant(String(localized: "command.browserSplitRight.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitDown",
                title: constant(String(localized: "command.browserSplitDown.title", defaultValue: "Split Browser Down")),
                subtitle: constant(String(localized: "command.browserSplitDown.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserDuplicateRight",
                title: constant(String(localized: "command.browserDuplicateRight.title", defaultValue: "Duplicate Browser to the Right")),
                subtitle: constant(String(localized: "command.browserDuplicateRight.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "duplicate", "clone", "split"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: target.commandPaletteCommandId,
                    title: constant(target.commandPaletteTitle),
                    subtitle: terminalPanelSubtitle,
                    keywords: target.commandPaletteKeywords,
                    when: { context in
                        context.bool(CommandPaletteContextKeys.panelIsTerminal)
                    }
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebStop",
                title: constant(String(localized: "command.vscodeServeWebStop.title", defaultValue: "Stop VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "stop", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebRestart",
                title: constant(String(localized: "command.vscodeServeWebRestart.title", defaultValue: "Restart VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "restart", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFind",
                title: constant(String(localized: "command.terminalFind.title", defaultValue: "Find…")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘F",
                keywords: ["terminal", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindNext",
                title: constant(String(localized: "command.terminalFindNext.title", defaultValue: "Find Next")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘G",
                keywords: ["terminal", "find", "next", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindPrevious",
                title: constant(String(localized: "command.terminalFindPrevious.title", defaultValue: "Find Previous")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌥⌘G",
                keywords: ["terminal", "find", "previous", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalHideFind",
                title: constant(String(localized: "command.terminalHideFind.title", defaultValue: "Hide Find Bar")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘⇧F",
                keywords: ["terminal", "hide", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalUseSelectionForFind",
                title: constant(String(localized: "command.terminalUseSelectionForFind.title", defaultValue: "Use Selection for Find")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "selection", "find"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitRight",
                title: constant(String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")),
                subtitle: constant(String(localized: "command.terminalSplitRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitDown",
                title: constant(String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")),
                subtitle: constant(String(localized: "command.terminalSplitDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserRight",
                title: constant(String(localized: "command.terminalSplitBrowserRight.title", defaultValue: "Split Browser Right")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserDown",
                title: constant(String(localized: "command.terminalSplitBrowserDown.title", defaultValue: "Split Browser Down")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSplitZoom",
                title: constant(String(localized: "command.toggleSplitZoom.title", defaultValue: "Toggle Pane Zoom")),
                subtitle: constant(String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "pane", "split", "zoom", "maximize"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    context.bool(CommandPaletteContextKeys.workspaceHasSplits)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.equalizeSplits",
                title: constant(String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits")),
                subtitle: workspaceSubtitle,
                keywords: ["split", "equalize", "balance", "divider", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            )
        )

        let cmuxConfigDefaultSubtitle = constant(String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json"))
        for command in cmuxConfigStore.loadedCommands {
            let commandName = sanitizeCmuxConfigPaletteText(command.name)
            let subtitle = command.description
                .map { sanitizeCmuxConfigPaletteText($0) }
                .flatMap { $0.isEmpty ? nil : constant($0) }
                ?? cmuxConfigDefaultSubtitle
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: command.id,
                    title: constant(String(localized: "command.cmuxConfig.customTitle", defaultValue: "Custom: \(commandName)")),
                    subtitle: subtitle,
                    keywords: command.keywords ?? []
                )
            )
        }

        return contributions
    }

    private func sanitizeCmuxConfigPaletteText(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(text.unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func registerCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newWorkspace") {
            tabManager.addWorkspace()
        }
        registry.register(commandId: "palette.openFolder") {
            // Defer so the command palette dismisses before the modal sheet appears.
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = String(localized: "panel.openFolder.title", defaultValue: "Open Folder")
                panel.prompt = String(localized: "panel.openFolder.prompt", defaultValue: "Open")
                if panel.runModal() == .OK, let url = panel.url {
                    tabManager.addWorkspace(workingDirectory: url.path)
                }
            }
        }
        registry.register(commandId: "palette.openFolderInVSCodeInline") {
            DispatchQueue.main.async {
                AppDelegate.shared?.showOpenFolderInInlineVSCodePanel(tabManager: tabManager)
            }
        }
        registry.register(commandId: "palette.newWindow") {
            AppDelegate.shared?.openNewMainWindow(nil)
        }
        registry.register(commandId: "palette.installCLI") {
            AppDelegate.shared?.installCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.uninstallCLI") {
            AppDelegate.shared?.uninstallCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.newTerminalTab") {
            tabManager.newSurface()
        }
        registry.register(commandId: "palette.newBrowserTab") {
            // Let command-palette dismissal complete first so omnibar focus
            // is not blocked by the palette visibility guard.
            DispatchQueue.main.async {
                _ = AppDelegate.shared?.openBrowserAndFocusAddressBar()
            }
        }
        registry.register(commandId: "palette.closeTab") {
            tabManager.closeCurrentPanelWithConfirmation()
        }
        registry.register(commandId: "palette.closeWorkspace") {
            tabManager.closeCurrentWorkspaceWithConfirmation()
        }
        registry.register(commandId: "palette.closeWindow") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            if let appDelegate = AppDelegate.shared {
                appDelegate.closeWindowWithConfirmation(window)
            } else {
                window.performClose(nil)
            }
        }
        registry.register(commandId: "palette.toggleFullScreen") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            window.toggleFullScreen(nil)
        }
        registry.register(commandId: "palette.reopenClosedBrowserTab") {
            _ = tabManager.reopenMostRecentlyClosedBrowserPanel()
        }
        registry.register(commandId: "palette.toggleSidebar") {
            sidebarState.toggle()
        }
        registry.register(commandId: "palette.enableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.minimal.rawValue
        }
        registry.register(commandId: "palette.disableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.standard.rawValue
        }
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.showNotifications") {
            AppDelegate.shared?.toggleNotificationsPopover(animated: false)
        }
        registry.register(commandId: "palette.jumpUnread") {
            AppDelegate.shared?.jumpToLatestUnread()
        }
        registry.register(commandId: "palette.openSettings") {
#if DEBUG
            dlog("palette.openSettings.invoke")
#endif
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(debugSource: "palette.openSettings")
            } else {
#if DEBUG
                dlog("palette.openSettings.missingAppDelegate fallback=1")
#endif
                AppDelegate.presentPreferencesWindow()
            }
        }
        registry.register(commandId: "palette.checkForUpdates") {
            AppDelegate.shared?.checkForUpdates(nil)
        }
        registry.register(commandId: "palette.applyUpdateIfAvailable") {
            AppDelegate.shared?.applyUpdateIfAvailable(nil)
        }
        registry.register(commandId: "palette.attemptUpdate") {
            AppDelegate.shared?.attemptUpdate(nil)
        }
        registry.register(commandId: "palette.restartSocketListener") {
            AppDelegate.shared?.restartSocketListener(nil)
        }

        registry.register(commandId: "palette.renameWorkspace") {
            beginRenameWorkspaceFlow()
        }
        registry.register(commandId: "palette.editWorkspaceDescription") {
            beginWorkspaceDescriptionFlow()
        }
        registry.register(commandId: "palette.clearWorkspaceName") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomTitle(tabId: workspace.id)
        }
        registry.register(commandId: "palette.clearWorkspaceDescription") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomDescription(tabId: workspace.id)
        }
        registry.register(commandId: "palette.toggleWorkspacePin") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.setPinned(workspace, pinned: !workspace.isPinned)
        }
        registry.register(commandId: "palette.nextWorkspace") {
            tabManager.selectNextTab()
        }
        registry.register(commandId: "palette.previousWorkspace") {
            tabManager.selectPreviousTab()
        }
        registry.register(commandId: "palette.moveWorkspaceUp") {
            moveSelectedWorkspace(by: -1)
        }
        registry.register(commandId: "palette.moveWorkspaceDown") {
            moveSelectedWorkspace(by: 1)
        }
        registry.register(commandId: "palette.moveWorkspaceToTop") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.moveTabsToTop([workspace.id])
            tabManager.selectWorkspace(workspace)
        }
        registry.register(commandId: "palette.closeOtherWorkspaces") {
            closeOtherSelectedWorkspaces()
        }
        registry.register(commandId: "palette.closeWorkspacesBelow") {
            closeSelectedWorkspacesBelow()
        }
        registry.register(commandId: "palette.closeWorkspacesAbove") {
            closeSelectedWorkspacesAbove()
        }
        registry.register(commandId: "palette.markWorkspaceRead") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markRead(forTabId: workspaceId)
        }
        registry.register(commandId: "palette.markWorkspaceUnread") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markUnread(forTabId: workspaceId)
        }

        registry.register(commandId: "palette.renameTab") {
            beginRenameTabFlow()
        }
        registry.register(commandId: "palette.clearTabName") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelCustomTitle(panelId: panelContext.panelId, title: nil)
        }
        registry.register(commandId: "palette.toggleTabPin") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelPinned(
                panelId: panelContext.panelId,
                pinned: !panelContext.workspace.isPanelPinned(panelContext.panelId)
            )
        }
        registry.register(commandId: "palette.toggleTabUnread") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            let hasUnread = panelContext.workspace.manualUnreadPanelIds.contains(panelContext.panelId)
                || notificationStore.hasUnreadNotification(forTabId: panelContext.workspace.id, surfaceId: panelContext.panelId)
            if hasUnread {
                panelContext.workspace.markPanelRead(panelContext.panelId)
            } else {
                panelContext.workspace.markPanelUnread(panelContext.panelId)
            }
        }
        registry.register(commandId: "palette.nextTabInPane") {
            tabManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            tabManager.selectPreviousSurface()
        }
        registry.register(commandId: "palette.openWorkspacePullRequests") {
            DispatchQueue.main.async {
                if !openWorkspacePullRequestsInConfiguredBrowser() {
                    NSSound.beep()
                }
            }
        }

        registry.register(commandId: "palette.browserBack") {
            tabManager.focusedBrowserPanel?.goBack()
        }
        registry.register(commandId: "palette.browserForward") {
            tabManager.focusedBrowserPanel?.goForward()
        }
        registry.register(commandId: "palette.browserReload") {
            tabManager.focusedBrowserPanel?.reload()
        }
        registry.register(commandId: "palette.browserOpenDefault") {
            if !openFocusedBrowserInDefaultBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusAddressBar") {
            if !focusFocusedBrowserAddressBar() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleDevTools") {
            if !tabManager.toggleDeveloperToolsFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserConsole") {
            if !tabManager.showJavaScriptConsoleFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserReactGrab") {
            if !tabManager.toggleReactGrabFromCurrentFocus() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomIn") {
            if !tabManager.zoomInFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomOut") {
            if !tabManager.zoomOutFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomReset") {
            if !tabManager.resetZoomFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserClearHistory") {
            BrowserHistoryStore.shared.clearHistory()
        }
        registry.register(commandId: "palette.browserSplitRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.browserSplitDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.browserDuplicateRight") {
            let url = tabManager.focusedBrowserPanel?.preferredURLStringForOmnibar().flatMap(URL.init(string:))
            _ = tabManager.createBrowserSplit(direction: .right, url: url)
        }

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            registry.register(commandId: target.commandPaletteCommandId) {
                if !openFocusedDirectory(in: target) {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.vscodeServeWebStop") {
            stopInlineVSCodeServeWeb()
        }
        registry.register(commandId: "palette.vscodeServeWebRestart") {
            if !restartInlineVSCodeServeWeb() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalFind") {
            tabManager.startSearch()
        }
        registry.register(commandId: "palette.terminalFindNext") {
            tabManager.findNext()
        }
        registry.register(commandId: "palette.terminalFindPrevious") {
            tabManager.findPrevious()
        }
        registry.register(commandId: "palette.terminalHideFind") {
            tabManager.hideFind()
        }
        registry.register(commandId: "palette.terminalUseSelectionForFind") {
            tabManager.searchSelection()
        }
        registry.register(commandId: "palette.terminalSplitRight") {
            tabManager.createSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitDown") {
            tabManager.createSplit(direction: .down)
        }
        registry.register(commandId: "palette.terminalSplitBrowserRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitBrowserDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.toggleSplitZoom") {
            if !tabManager.toggleFocusedSplitZoom() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.equalizeSplits") {
            guard let workspace = tabManager.selectedWorkspace,
                  tabManager.equalizeSplits(tabId: workspace.id) else {
                NSSound.beep()
                return
            }
        }

        for command in cmuxConfigStore.loadedCommands {
            let captured = command
            let sourcePath = cmuxConfigStore.commandSourcePaths[command.id]
            let globalPath = cmuxConfigStore.globalConfigPath
            registry.register(commandId: command.id) {
                let rawCwd = tabManager.selectedWorkspace?.currentDirectory
                let baseCwd = (rawCwd?.isEmpty == false) ? rawCwd!
                    : FileManager.default.homeDirectoryForCurrentUser.path
                CmuxConfigExecutor.execute(
                    command: captured,
                    tabManager: tabManager,
                    baseCwd: baseCwd,
                    configSourcePath: sourcePath,
                    globalConfigPath: globalPath
                )
            }
        }
    }

    private var focusedPanelContext: (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    private static func commandPaletteWorkspaceDisplayName(_ workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom
        }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : title
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        Self.commandPaletteWorkspaceDisplayName(workspace)
    }

    private func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? String(localized: "panel.displayName.fallback", defaultValue: "Tab") : trimmedFallback
    }

    private func commandPaletteSelectedIndex(resultCount: Int) -> Int {
        guard resultCount > 0 else { return 0 }
        return min(max(commandPaletteSelectedResultIndex, 0), resultCount - 1)
    }

    static func commandPaletteResolvedSelectionIndex(
        preferredCommandID: String?,
        fallbackSelectedIndex: Int,
        resultIDs: [String]
    ) -> Int {
        guard !resultIDs.isEmpty else { return 0 }
        if let preferredCommandID,
           let anchoredIndex = resultIDs.firstIndex(of: preferredCommandID) {
            return anchoredIndex
        }
        return min(max(fallbackSelectedIndex, 0), resultIDs.count - 1)
    }

    static func commandPaletteSelectionAnchorCommandID(
        selectedIndex: Int,
        resultIDs: [String]
    ) -> String? {
        guard !resultIDs.isEmpty else { return nil }
        let resolvedIndex = min(max(selectedIndex, 0), resultIDs.count - 1)
        return resultIDs[resolvedIndex]
    }

    static func commandPalettePendingActivationRequestID(
        _ pendingActivation: CommandPalettePendingActivation?
    ) -> UInt64? {
        switch pendingActivation {
        case .selected(let requestID, _, _):
            return requestID
        case .command(let requestID, _):
            return requestID
        case nil:
            return nil
        }
    }

    static func commandPaletteResolvedPendingActivation(
        _ pendingActivation: CommandPalettePendingActivation?,
        requestID: UInt64,
        resultIDs: [String]
    ) -> CommandPaletteResolvedActivation? {
        switch pendingActivation {
        case .selected(let activationRequestID, let fallbackSelectedIndex, let preferredCommandID):
            guard activationRequestID == requestID else { return nil }
            let resolvedIndex = commandPaletteResolvedSelectionIndex(
                preferredCommandID: preferredCommandID,
                fallbackSelectedIndex: fallbackSelectedIndex,
                resultIDs: resultIDs
            )
            return .selected(index: resolvedIndex)
        case .command(let activationRequestID, let commandID):
            guard activationRequestID == requestID, resultIDs.contains(commandID) else { return nil }
            return .command(commandID: commandID)
        case nil:
            return nil
        }
    }

    static func commandPaletteContextFingerprint(
        boolValues: [String: Bool],
        stringValues: [String: String]
    ) -> Int {
        var hasher = Hasher()
        for key in boolValues.keys.sorted() {
            hasher.combine(key)
            hasher.combine(boolValues[key] ?? false)
        }
        for key in stringValues.keys.sorted() {
            hasher.combine(key)
            hasher.combine(stringValues[key] ?? "")
        }
        return hasher.finalize()
    }

    static func commandPaletteSwitcherFingerprint(
        windowContexts: [CommandPaletteSwitcherFingerprintContext]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(windowContexts.count)
        for context in windowContexts {
            hasher.combine(context.windowId)
            hasher.combine(context.windowLabel)
            hasher.combine(context.selectedWorkspaceId)
            hasher.combine(context.workspaces.count)
            for workspace in context.workspaces {
                hasher.combine(workspace.id)
                hasher.combine(workspace.displayName)
                combineCommandPaletteSwitcherSearchMetadata(workspace.metadata, into: &hasher)
                hasher.combine(workspace.surfaces.count)
                for surface in workspace.surfaces {
                    hasher.combine(surface.id)
                    hasher.combine(surface.displayName)
                    hasher.combine(surface.kindLabel)
                    combineCommandPaletteSwitcherSearchMetadata(surface.metadata, into: &hasher)
                }
            }
        }
        return hasher.finalize()
    }

    static func combineCommandPaletteSwitcherSearchMetadata(
        _ metadata: CommandPaletteSwitcherSearchMetadata,
        into hasher: inout Hasher
    ) {
        hasher.combine(metadata.directories.count)
        for directory in metadata.directories {
            hasher.combine(directory)
        }
        hasher.combine(metadata.branches.count)
        for branch in metadata.branches {
            hasher.combine(branch)
        }
        hasher.combine(metadata.ports.count)
        for port in metadata.ports {
            hasher.combine(port)
        }
        hasher.combine(metadata.description ?? "")
    }

    static func commandPaletteScrollPositionAnchor(
        selectedIndex: Int,
        resultCount: Int
    ) -> UnitPoint? {
        guard resultCount > 0 else { return nil }
        if selectedIndex <= 0 {
            return UnitPoint.top
        }
        if selectedIndex >= resultCount - 1 {
            return UnitPoint.bottom
        }
        return nil
    }

    private func updateCommandPaletteScrollTarget(resultCount: Int, animated: Bool) {
        guard resultCount > 0 else {
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            return
        }

        let selectedIndex = commandPaletteSelectedIndex(resultCount: resultCount)
        commandPaletteScrollTargetAnchor = Self.commandPaletteScrollPositionAnchor(
            selectedIndex: selectedIndex,
            resultCount: resultCount
        )

        let assignTarget = {
            commandPaletteScrollTargetIndex = selectedIndex
        }
        if animated {
            withAnimation(.easeOut(duration: 0.1)) {
                assignTarget()
            }
        } else {
            assignTarget()
        }
    }

    private func syncCommandPaletteSelectionAnchor(resultIDs: [String]) {
        commandPaletteSelectionAnchorCommandID = Self.commandPaletteSelectionAnchorCommandID(
            selectedIndex: commandPaletteSelectedResultIndex,
            resultIDs: resultIDs
        )
    }

    private func syncCommandPaletteSelectionAnchorFromCurrentResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: cachedCommandPaletteResults.map(\.id))
    }

    private func syncCommandPaletteSelectionAnchorFromVisibleResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: commandPaletteVisibleResults.map(\.id))
    }

    private func moveCommandPaletteSelection(by delta: Int) {
        let count = commandPaletteVisibleResults.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        let current = commandPaletteSelectedIndex(resultCount: count)
        commandPaletteSelectedResultIndex = min(max(current + delta, 0), count - 1)
        if commandPaletteHasCurrentResolvedResults {
            syncCommandPaletteSelectionAnchorFromCurrentResults()
        } else {
            syncCommandPaletteSelectionAnchorFromVisibleResults()
        }
        syncCommandPaletteDebugStateForObservedWindow()
    }

    static func commandPaletteShouldPopRenameInputOnDelete(
        renameDraft: String,
        modifiers: EventModifiers
    ) -> Bool {
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return renameDraft.isEmpty
    }

    private func handleCommandPaletteRenameDeleteBackward(
        modifiers: EventModifiers
    ) -> BackportKeyPressResult {
        guard case .renameInput = commandPaletteMode else { return .ignored }
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return .ignored }

        if Self.commandPaletteShouldPopRenameInputOnDelete(
            renameDraft: commandPaletteRenameDraft,
            modifiers: modifiers
        ) {
            commandPaletteMode = .commands
            resetCommandPaletteSearchFocus()
            syncCommandPaletteDebugStateForObservedWindow()
            return .handled
        }

        if let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
           let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor {
            editor.deleteBackward(nil)
            commandPaletteRenameDraft = editor.string
        } else if !commandPaletteRenameDraft.isEmpty {
            commandPaletteRenameDraft.removeLast()
        }

        syncCommandPaletteDebugStateForObservedWindow()
        return .handled
    }

    private var commandPaletteHasCurrentResolvedResults: Bool {
        !isCommandPaletteSearchPending && commandPaletteResolvedSearchRequestID == commandPaletteSearchRequestID
    }

    private var commandPaletteShouldShowEmptyState: Bool {
        guard commandPaletteVisibleResults.isEmpty else { return false }
        if commandPaletteHasCurrentResolvedResults {
            return true
        }

        return Self.commandPaletteShouldPreserveEmptyStateWhileSearchPending(
            isSearchPending: isCommandPaletteSearchPending,
            visibleResultsScopeMatches: commandPaletteVisibleResultsScope == commandPaletteListScope,
            resolvedSearchScopeMatches: commandPaletteResolvedSearchScope == commandPaletteListScope,
            resolvedSearchFingerprintMatches: commandPaletteResolvedSearchFingerprint == commandPaletteVisibleResultsFingerprint,
            resolvedResultsAreEmpty: cachedCommandPaletteResults.isEmpty,
            currentMatchingQuery: commandPaletteQueryForMatching,
            resolvedMatchingQuery: commandPaletteResolvedMatchingQuery
        )
    }

    private func runCommandPaletteResolvedActivation(_ activation: CommandPaletteResolvedActivation) {
        switch activation {
        case .command(let commandID):
            guard let command = cachedCommandPaletteResults.first(where: { $0.id == commandID })?.command else {
                return
            }
            runCommandPaletteCommand(command)
        case .selected(let fallbackIndex):
            guard !cachedCommandPaletteResults.isEmpty else {
                NSSound.beep()
                return
            }
            let resolvedIndex = Self.commandPaletteResolvedSelectionIndex(
                preferredCommandID: commandPaletteSelectionAnchorCommandID,
                fallbackSelectedIndex: fallbackIndex,
                resultIDs: cachedCommandPaletteResults.map(\.id)
            )
            commandPaletteSelectedResultIndex = resolvedIndex
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            runCommandPaletteCommand(cachedCommandPaletteResults[resolvedIndex].command)
        }
    }

    private func runCommandPaletteResult(commandID: String) {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePendingActivation = .command(
                    requestID: commandPaletteSearchRequestID,
                    commandID: commandID
                )
            }
            return
        }
        runCommandPaletteResolvedActivation(.command(commandID: commandID))
    }

    private func runSelectedCommandPaletteResult() {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePendingActivation = .selected(
                    requestID: commandPaletteSearchRequestID,
                    fallbackSelectedIndex: commandPaletteSelectedResultIndex,
                    preferredCommandID: commandPaletteSelectionAnchorCommandID
                )
            }
            return
        }

        runCommandPaletteResolvedActivation(.selected(index: commandPaletteSelectedResultIndex))
    }

    private func handleCommandPaletteSubmitRequest() {
        switch commandPaletteMode {
        case .commands:
            runSelectedCommandPaletteResult()
        case .renameInput(let target):
            continueRenameFlow(target: target)
        case .renameConfirm(let target, let proposedName):
            applyRenameFlow(target: target, proposedName: proposedName)
        case .workspaceDescriptionInput(let target):
#if DEBUG
            let newlineCount = commandPaletteWorkspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.submit.request workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "draftLen=\((commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount)"
            )
#endif
            applyWorkspaceDescriptionFlow(
                target: target,
                proposedDescription: commandPaletteWorkspaceDescriptionDraft
            )
        }
    }

    private func runCommandPaletteCommand(_ command: CommandPaletteCommand) {
#if DEBUG
        dlog("palette.run commandId=\(command.id) dismissOnRun=\(command.dismissOnRun ? 1 : 0)")
#endif
        recordCommandPaletteUsage(command.id)
        command.action()
        if command.dismissOnRun {
            dismissCommandPalette(restoreFocus: false)
        }
    }

    private func toggleCommandPalette() {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
    }

    private func openCommandPaletteCommands() {
        handleCommandPaletteListRequest(scope: .commands)
    }

    private func openCommandPaletteSwitcher() {
        handleCommandPaletteListRequest(scope: .switcher)
    }

    private func handleCommandPaletteListRequest(scope: CommandPaletteListScope) {
        let initialQuery = (scope == .commands) ? Self.commandPaletteCommandsPrefix : ""
        guard isCommandPalettePresented else {
            presentCommandPalette(initialQuery: initialQuery)
            return
        }

        if case .commands = commandPaletteMode,
           commandPaletteListScope == scope {
            dismissCommandPalette()
            return
        }

        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func openCommandPaletteRenameTabInput() {
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameTabFlow()
    }

    private func openCommandPaletteRenameWorkspaceInput() {
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameWorkspaceFlow()
    }

    private func openCommandPaletteWorkspaceDescriptionInput() {
#if DEBUG
        dlog(
            "palette.wsDescription.open begin presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
            "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))}"
        )
#endif
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginWorkspaceDescriptionFlow()
#if DEBUG
        dlog(
            "palette.wsDescription.open end presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
            "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
    }

    private func presentFeedbackComposer() {
        DispatchQueue.main.async {
            isFeedbackComposerPresented = true
        }
    }

    static func shouldHandleCommandPaletteRequest(
        observedWindow: NSWindow?,
        requestedWindow: NSWindow?,
        keyWindow: NSWindow?,
        mainWindow: NSWindow?
    ) -> Bool {
        guard let observedWindow else { return false }
        if let requestedWindow {
            return requestedWindow === observedWindow
        }
        if let keyWindow {
            return keyWindow === observedWindow
        }
        if let mainWindow {
            return mainWindow === observedWindow
        }
        return false
    }

    static func shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
        focusedPanelIsBrowser: Bool,
        focusedBrowserAddressBarPanelId: UUID?,
        focusedPanelId: UUID?
    ) -> Bool {
        focusedPanelIsBrowser && focusedBrowserAddressBarPanelId == focusedPanelId
    }

    private func syncCommandPaletteDebugStateForObservedWindow() {
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        AppDelegate.shared?.setCommandPaletteVisible(isCommandPalettePresented, for: window)
        let visibleResultCount = commandPaletteVisibleResults.count
        let selectedIndex = isCommandPalettePresented ? commandPaletteSelectedIndex(resultCount: visibleResultCount) : 0
        AppDelegate.shared?.setCommandPaletteSelectionIndex(selectedIndex, for: window)
        AppDelegate.shared?.setCommandPaletteSnapshot(commandPaletteDebugSnapshot(), for: window)
    }

    private func commandPaletteDebugSnapshot() -> CommandPaletteDebugSnapshot {
        guard isCommandPalettePresented else { return .empty }

        let mode: String
        switch commandPaletteMode {
        case .commands:
            mode = commandPaletteListScope.rawValue
        case .renameInput:
            mode = "rename_input"
        case .renameConfirm:
            mode = "rename_confirm"
        case .workspaceDescriptionInput:
            mode = "workspace_description_input"
        }

        let rows = Array(commandPaletteVisibleResults.prefix(20)).map { result in
                CommandPaletteDebugResultRow(
                    commandId: result.command.id,
                    title: result.command.title,
                    shortcutHint: result.command.shortcutHint,
                    trailingLabel: commandPaletteTrailingLabel(for: result.command)?.text,
                    score: result.score
                )
        }

        return CommandPaletteDebugSnapshot(
            query: commandPaletteQueryForMatching,
            mode: mode,
            results: rows
        )
    }

    private func presentCommandPalette(initialQuery: String) {
        if let panelContext = focusedPanelContext {
            commandPaletteRestoreFocusTarget = CommandPaletteRestoreFocusTarget(
                workspaceId: panelContext.workspace.id,
                panelId: panelContext.panelId,
                intent: panelContext.panel.captureFocusIntent(in: observedWindow)
            )
        } else {
            commandPaletteRestoreFocusTarget = nil
        }
        isCommandPalettePresented = true
        refreshCommandPaletteUsageHistory()
        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func resetCommandPaletteListState(initialQuery: String) {
        commandPaletteMode = .commands
        commandPaletteQuery = initialQuery
        commandPaletteRenameDraft = ""
        commandPaletteWorkspaceDescriptionDraft = ""
        commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPaletteSelectedResultIndex = 0
        commandPaletteSelectionAnchorCommandID = nil
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true)
        resetCommandPaletteSearchFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func dismissCommandPalette(restoreFocus: Bool = true) {
        dismissCommandPalette(restoreFocus: restoreFocus, preferredFocusTarget: nil)
    }

    private func dismissCommandPalette(
        restoreFocus: Bool,
        preferredFocusTarget: CommandPaletteRestoreFocusTarget?
    ) {
        let focusTarget = preferredFocusTarget ?? commandPaletteRestoreFocusTarget
#if DEBUG
        if case .workspaceDescriptionInput(let target) = commandPaletteMode {
            let newlineCount = commandPaletteWorkspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.dismiss workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "restoreFocus=\(restoreFocus ? 1 : 0) " +
                "draftLen=\((commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))}"
            )
        }
#endif
        cancelCommandPaletteSearch()
        commandPaletteSearchRequestID &+= 1
        isCommandPalettePresented = false
        commandPaletteMode = .commands
        commandPaletteQuery = ""
        commandPaletteRenameDraft = ""
        commandPaletteWorkspaceDescriptionDraft = ""
        commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPaletteSelectedResultIndex = 0
        commandPaletteSelectionAnchorCommandID = nil
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        isCommandPaletteSearchFocused = false
        isCommandPaletteRenameFocused = false
        commandPaletteRestoreFocusTarget = nil
        commandPaletteSearchCorpus = []
        commandPaletteSearchCorpusByID = [:]
        commandPaletteSearchCommandsByID = [:]
        cachedCommandPaletteResults = []
        commandPaletteVisibleResults = []
        commandPaletteVisibleResultsScope = nil
        commandPaletteVisibleResultsFingerprint = nil
        cachedCommandPaletteScope = nil
        cachedCommandPaletteFingerprint = nil
        commandPalettePendingTextSelectionBehavior = nil
        commandPaletteResolvedSearchRequestID = commandPaletteSearchRequestID
        commandPaletteResolvedSearchScope = nil
        commandPaletteResolvedSearchFingerprint = nil
        commandPaletteTerminalOpenTargetAvailability = []
        isCommandPaletteSearchPending = false
        commandPalettePendingActivation = nil
        commandPaletteResultsRevision &+= 1
        if let window = observedWindow {
            _ = window.makeFirstResponder(nil)
        }
        syncCommandPaletteDebugStateForObservedWindow()

        guard restoreFocus, let focusTarget else { return }
        requestCommandPaletteFocusRestore(target: focusTarget)
    }

    private func handleCommandPaletteBackdropClick(atContentPoint contentPoint: CGPoint) {
        let clickedFocusTarget = commandPaletteBackdropFocusTarget(atContentPoint: contentPoint)
#if DEBUG
        if let clickedFocusTarget {
            dlog(
                "palette.dismiss.backdrop focusTarget panel=\(clickedFocusTarget.panelId.uuidString.prefix(5)) " +
                "workspace=\(clickedFocusTarget.workspaceId.uuidString.prefix(5)) intent=\(debugCommandPaletteFocusIntent(clickedFocusTarget.intent))"
            )
        } else {
            dlog("palette.dismiss.backdrop focusTarget=nil")
        }
#endif
        dismissCommandPalette(restoreFocus: true, preferredFocusTarget: clickedFocusTarget)
    }

    private func commandPaletteBackdropFocusTarget(atContentPoint contentPoint: CGPoint) -> CommandPaletteRestoreFocusTarget? {
        guard let window = observedWindow,
              let contentView = window.contentView else {
            return nil
        }

        let nsContentPoint = NSPoint(x: contentPoint.x, y: contentPoint.y)
        let windowPoint = contentView.convert(nsContentPoint, to: nil)
        return commandPaletteBackdropFocusTarget(atWindowPoint: windowPoint, in: window)
    }

    private func commandPaletteBackdropFocusTarget(
        atWindowPoint windowPoint: NSPoint,
        in window: NSWindow
    ) -> CommandPaletteRestoreFocusTarget? {
        let overlayController = commandPaletteWindowOverlayController(for: window)
        if let responder = overlayController.underlyingResponder(atWindowPoint: windowPoint),
           let target = commandPaletteBackdropFocusTarget(for: responder) {
            return target
        }

        if let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window),
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        if let terminalView = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: window
            )
        }

        return nil
    }

    private func commandPaletteBackdropFocusTarget(for responder: NSResponder) -> CommandPaletteRestoreFocusTarget? {
        if let terminalView = cmuxOwningGhosttyView(for: responder),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: observedWindow
            )
        }

        if let webView = commandPaletteOwningWebView(for: responder),
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(for webView: WKWebView) -> CommandPaletteRestoreFocusTarget? {
        if let selectedWorkspace = tabManager.selectedWorkspace,
           let target = commandPaletteBrowserFocusTarget(in: selectedWorkspace, for: webView) {
            return target
        }

        let selectedWorkspaceId = tabManager.selectedTabId
        for workspace in tabManager.tabs where workspace.id != selectedWorkspaceId {
            if let target = commandPaletteBrowserFocusTarget(in: workspace, for: webView) {
                return target
            }
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(
        in workspace: Workspace,
        for webView: WKWebView
    ) -> CommandPaletteRestoreFocusTarget? {
        for (panelId, panel) in workspace.panels {
            guard let browserPanel = panel as? BrowserPanel,
                  browserPanel.webView === webView else {
                continue
            }

            return commandPaletteRestoreFocusTarget(
                workspaceId: workspace.id,
                panelId: panelId,
                fallbackIntent: .browser(.webView),
                in: observedWindow
            )
        }

        return nil
    }

    private func commandPaletteRestoreFocusTarget(
        workspaceId: UUID,
        panelId: UUID,
        fallbackIntent: PanelFocusIntent,
        in window: NSWindow?
    ) -> CommandPaletteRestoreFocusTarget {
        let intent = tabManager.tabs
            .first(where: { $0.id == workspaceId })?
            .panels[panelId]?
            .captureFocusIntent(in: window) ?? fallbackIntent

        return CommandPaletteRestoreFocusTarget(
            workspaceId: workspaceId,
            panelId: panelId,
            intent: intent
        )
    }

    private func requestCommandPaletteFocusRestore(target: CommandPaletteRestoreFocusTarget) {
        commandPalettePendingDismissFocusTarget = target
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        let timeoutWork = DispatchWorkItem {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem = nil
        }
        commandPaletteRestoreTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutWork)
        attemptCommandPaletteFocusRestoreIfNeeded()
    }

    private func attemptCommandPaletteFocusRestoreIfNeeded() {
        guard !isCommandPalettePresented else { return }
        guard let target = commandPalettePendingDismissFocusTarget else { return }
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem?.cancel()
            commandPaletteRestoreTimeoutWorkItem = nil
            return
        }

        if let window = observedWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        tabManager.focusTab(target.workspaceId, surfaceId: target.panelId, suppressFlash: true)

        guard let context = focusedPanelContext,
              context.workspace.id == target.workspaceId,
              context.panelId == target.panelId else {
            return
        }
        guard context.panel.restoreFocusIntent(target.intent) else { return }
        commandPalettePendingDismissFocusTarget = nil
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        commandPaletteRestoreTimeoutWorkItem = nil
    }

#if DEBUG
    private func debugCommandPaletteFocusIntent(_ intent: PanelFocusIntent) -> String {
        switch intent {
        case .panel:
            return "panel"
        case .terminal(.surface):
            return "terminal.surface"
        case .terminal(.findField):
            return "terminal.findField"
        case .browser(.webView):
            return "browser.webView"
        case .browser(.addressBar):
            return "browser.addressBar"
        case .browser(.findField):
            return "browser.findField"
        }
    }

    private func debugCommandPaletteModeLabel(_ mode: CommandPaletteMode) -> String {
        switch mode {
        case .commands:
            return "commands"
        case .renameInput:
            return "renameInput"
        case .renameConfirm:
            return "renameConfirm"
        case .workspaceDescriptionInput:
            return "workspaceDescriptionInput"
        }
    }
#endif

    private func resetCommandPaletteSearchFocus() {
        applyCommandPaletteInputFocusPolicy(.search)
    }

    private func resetCommandPaletteRenameFocus() {
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func resetCommandPaletteWorkspaceDescriptionFocus() {
#if DEBUG
        dlog(
            "palette.wsDescription.focus.reset schedule presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
            "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
        DispatchQueue.main.async {
#if DEBUG
            dlog(
                "palette.wsDescription.focus.reset apply.before search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
            isCommandPaletteSearchFocused = false
            isCommandPaletteRenameFocused = false
            commandPaletteShouldFocusWorkspaceDescriptionEditor = true
            commandPalettePendingTextSelectionBehavior = nil
#if DEBUG
            dlog(
                "palette.wsDescription.focus.reset apply.after search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
        }
    }

    private func handleCommandPaletteRenameInputInteraction() {
        guard isCommandPalettePresented else { return }
        guard case .renameInput = commandPaletteMode else { return }
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func commandPaletteRenameInputFocusPolicy() -> CommandPaletteInputFocusPolicy {
        let selectAllOnFocus = CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled()
        let selectionBehavior: CommandPaletteTextSelectionBehavior = selectAllOnFocus
            ? .selectAll
            : .caretAtEnd
        return CommandPaletteInputFocusPolicy(
            focusTarget: .rename,
            selectionBehavior: selectionBehavior
        )
    }

    private func applyCommandPaletteInputFocusPolicy(_ policy: CommandPaletteInputFocusPolicy) {
        DispatchQueue.main.async {
            commandPaletteShouldFocusWorkspaceDescriptionEditor = false
            switch policy.focusTarget {
            case .search:
                isCommandPaletteRenameFocused = false
                isCommandPaletteSearchFocused = true
            case .rename:
                isCommandPaletteSearchFocused = false
                isCommandPaletteRenameFocused = true
            }
            applyCommandPaletteTextSelection(policy.selectionBehavior)
        }
    }

    private func applyCommandPaletteTextSelection(_ behavior: CommandPaletteTextSelectionBehavior) {
        commandPalettePendingTextSelectionBehavior = behavior
        attemptCommandPaletteTextSelectionIfNeeded()
    }

    private func attemptCommandPaletteTextSelectionIfNeeded() {
        guard isCommandPalettePresented else {
            commandPalettePendingTextSelectionBehavior = nil
            return
        }
        guard let behavior = commandPalettePendingTextSelectionBehavior else { return }
        switch behavior {
        case .selectAll:
            guard case .renameInput = commandPaletteMode else { return }
        case .caretAtEnd:
            switch commandPaletteMode {
            case .commands, .renameInput:
                break
            case .renameConfirm:
                return
            case .workspaceDescriptionInput:
                return
            }
        }
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        guard let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else {
            return
        }
        let length = (editor.string as NSString).length
        switch behavior {
        case .selectAll:
            editor.setSelectedRange(NSRange(location: 0, length: length))
        case .caretAtEnd:
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
        commandPalettePendingTextSelectionBehavior = nil
    }

    private func refreshCommandPaletteUsageHistory() {
        commandPaletteUsageHistoryByCommandId = loadCommandPaletteUsageHistory()
    }

    private func loadCommandPaletteUsageHistory() -> [String: CommandPaletteUsageEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.commandPaletteUsageDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: CommandPaletteUsageEntry].self, from: data)) ?? [:]
    }

    private func persistCommandPaletteUsageHistory(_ history: [String: CommandPaletteUsageEntry]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.commandPaletteUsageDefaultsKey)
    }

    private func recordCommandPaletteUsage(_ commandId: String) {
        var history = commandPaletteUsageHistoryByCommandId
        var entry = history[commandId] ?? CommandPaletteUsageEntry(useCount: 0, lastUsedAt: 0)
        entry.useCount += 1
        entry.lastUsedAt = Date().timeIntervalSince1970
        history[commandId] = entry
        commandPaletteUsageHistoryByCommandId = history
        persistCommandPaletteUsageHistory(history)
    }

    nonisolated private static func commandPaletteHistoryBoost(
        for commandId: String,
        queryIsEmpty: Bool,
        history: [String: CommandPaletteUsageEntry],
        now: TimeInterval
    ) -> Int {
        guard let entry = history[commandId] else { return 0 }

        let ageDays = max(0, now - entry.lastUsedAt) / 86_400
        let recencyBoost = max(0, 320 - Int(ageDays * 20))
        let countBoost = min(180, entry.useCount * 12)
        let totalBoost = recencyBoost + countBoost

        return queryIsEmpty ? totalBoost : max(0, totalBoost / 3)
    }

    private func commandPaletteHistoryBoost(for commandId: String, queryIsEmpty: Bool) -> Int {
        Self.commandPaletteHistoryBoost(
            for: commandId,
            queryIsEmpty: queryIsEmpty,
            history: commandPaletteUsageHistoryByCommandId,
            now: Date().timeIntervalSince1970
        )
    }

    private func selectedWorkspaceIndex() -> Int? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return tabManager.tabs.firstIndex { $0.id == workspace.id }
    }

    private func moveSelectedWorkspace(by delta: Int) {
        guard let workspace = tabManager.selectedWorkspace,
              let currentIndex = selectedWorkspaceIndex() else { return }
        let targetIndex = currentIndex + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: targetIndex)
        tabManager.selectWorkspace(workspace)
    }

    private func closeWorkspaceIds(_ workspaceIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: allowPinned)
    }

    private func closeOtherSelectedWorkspaces() {
        guard let workspace = tabManager.selectedWorkspace else { return }
        let workspaceIds = tabManager.tabs.compactMap { $0.id == workspace.id ? nil : $0.id }
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func closeSelectedWorkspacesBelow() {
        guard tabManager.selectedWorkspace != nil,
              let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.suffix(from: anchorIndex + 1).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func closeSelectedWorkspacesAbove() {
        guard tabManager.selectedWorkspace != nil,
              let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.prefix(upTo: anchorIndex).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func syncSidebarSelectedWorkspaceIds() {
        tabManager.setSidebarSelectedWorkspaceIds(selectedTabIds)
    }

    private func applyUITestSidebarSelectionIfNeeded(tabs: [Workspace]) {
#if DEBUG
        guard !didApplyUITestSidebarSelection else { return }
        let env = ProcessInfo.processInfo.environment
        guard let rawValue = env["CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return
        }

        var indices: [Int] = []
        for token in rawValue.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = Int(trimmed), index >= 0 else { return }
            if !indices.contains(index) {
                indices.append(index)
            }
        }

        guard let lastIndex = indices.last, !indices.isEmpty, lastIndex < tabs.count else { return }

        let selectedIds = Set(indices.map { tabs[$0].id })
        selectedTabIds = selectedIds
        lastSidebarSelectionIndex = lastIndex
        tabManager.selectWorkspace(tabs[lastIndex])
        sidebarSelectionState.selection = .tabs
        didApplyUITestSidebarSelection = true
#endif
    }

    private func beginRenameWorkspaceFlow() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: workspace.id),
            currentName: workspaceDisplayName(workspace)
        )
        startRenameFlow(target)
    }

    private func beginWorkspaceDescriptionFlow() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteWorkspaceDescriptionTarget(
            workspaceId: workspace.id,
            currentDescription: workspace.customDescription ?? ""
        )
        startWorkspaceDescriptionFlow(target)
    }

    private func beginRenameTabFlow() {
        guard let panelContext = focusedPanelContext else {
            NSSound.beep()
            return
        }
        let panelName = panelDisplayName(
            workspace: panelContext.workspace,
            panelId: panelContext.panelId,
            fallback: panelContext.panel.displayTitle
        )
        let target = CommandPaletteRenameTarget(
            kind: .tab(workspaceId: panelContext.workspace.id, panelId: panelContext.panelId),
            currentName: panelName
        )
        startRenameFlow(target)
    }

    private func startRenameFlow(_ target: CommandPaletteRenameTarget) {
        commandPaletteRenameDraft = target.currentName
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        commandPaletteMode = .renameInput(target)
        resetCommandPaletteRenameFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func startWorkspaceDescriptionFlow(_ target: CommandPaletteWorkspaceDescriptionTarget) {
#if DEBUG
        dlog(
            "palette.wsDescription.flow.start workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "descLen=\((target.currentDescription as NSString).length) " +
            "presented=\(isCommandPalettePresented ? 1 : 0) " +
            "modeBefore=\(debugCommandPaletteModeLabel(commandPaletteMode))"
        )
#endif
        commandPaletteWorkspaceDescriptionDraft = target.currentDescription
        commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPalettePendingTextSelectionBehavior = nil
        commandPaletteMode = .workspaceDescriptionInput(target)
        resetCommandPaletteWorkspaceDescriptionFocus()
#if DEBUG
        dlog(
            "palette.wsDescription.flow.armed workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "height=\(String(format: "%.1f", commandPaletteWorkspaceDescriptionHeight)) " +
            "modeAfter=\(debugCommandPaletteModeLabel(commandPaletteMode))"
        )
#endif
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func continueRenameFlow(target: CommandPaletteRenameTarget) {
        guard case .renameInput(let activeTarget) = commandPaletteMode,
              activeTarget == target else { return }
        applyRenameFlow(target: target, proposedName: commandPaletteRenameDraft)
    }

    private func applyRenameFlow(target: CommandPaletteRenameTarget, proposedName: String) {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName: String? = trimmedName.isEmpty ? nil : trimmedName

        switch target.kind {
        case .workspace(let workspaceId):
            tabManager.setCustomTitle(tabId: workspaceId, title: normalizedName)
        case .tab(let workspaceId, let panelId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                NSSound.beep()
                return
            }
            workspace.setPanelCustomTitle(panelId: panelId, title: normalizedName)
        }

        dismissCommandPalette()
    }

    private func applyWorkspaceDescriptionFlow(
        target: CommandPaletteWorkspaceDescriptionTarget,
        proposedDescription: String
    ) {
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            NSSound.beep()
            return
        }
#if DEBUG
        let newlineCount = proposedDescription.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        dlog(
            "palette.wsDescription.apply.begin workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "proposedLen=\((proposedDescription as NSString).length) " +
            "newlines=\(newlineCount) " +
            "text=\"\(debugCommandPaletteTextPreview(proposedDescription))\""
        )
#endif
        tabManager.setCustomDescription(tabId: target.workspaceId, description: proposedDescription)
#if DEBUG
        if let updatedWorkspace = tabManager.tabs.first(where: { $0.id == target.workspaceId }) {
            let persisted = updatedWorkspace.customDescription ?? ""
            let persistedNewlineCount = persisted.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.apply.end workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "persistedLen=\((persisted as NSString).length) " +
                "persistedNewlines=\(persistedNewlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(persisted))\""
            )
        }
#endif
        dismissCommandPalette()
    }

    private func focusFocusedBrowserAddressBar() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel else { return false }
        _ = panel.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
        return true
    }

    private func openFocusedBrowserInDefaultBrowser() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel,
              let rawURL = panel.preferredURLStringForOmnibar(),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func openWorkspacePullRequestsInConfiguredBrowser() -> Bool {
        guard let workspace = tabManager.selectedWorkspace else { return false }
        let pullRequests = workspace.sidebarPullRequestsInDisplayOrder()
        guard !pullRequests.isEmpty else { return false }

        var openedCount = 0
        if openSidebarPullRequestLinksInCmuxBrowser {
            for pullRequest in pullRequests {
                if tabManager.openBrowser(url: pullRequest.url, insertAtEnd: true) != nil {
                    openedCount += 1
                } else if NSWorkspace.shared.open(pullRequest.url) {
                    openedCount += 1
                }
            }
            return openedCount > 0
        }

        for pullRequest in pullRequests {
            if NSWorkspace.shared.open(pullRequest.url) {
                openedCount += 1
            }
        }
        return openedCount > 0
    }

    private func openFocusedDirectory(in target: TerminalDirectoryOpenTarget) -> Bool {
        guard let directoryURL = focusedTerminalDirectoryURL() else { return false }
        return openFocusedDirectory(directoryURL, in: target)
    }

    private func openFocusedDirectory(_ directoryURL: URL, in target: TerminalDirectoryOpenTarget) -> Bool {
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
            return true
        case .vscodeInline:
            return openFocusedDirectoryInInlineVSCode(directoryURL)
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
    }

    private func openFocusedDirectoryInInlineVSCode(_ directoryURL: URL) -> Bool {
        AppDelegate.shared?.openDirectoryInInlineVSCode(directoryURL, tabManager: tabManager) ?? false
    }

    private func stopInlineVSCodeServeWeb() {
        VSCodeServeWebController.shared.stop()
    }

    private func restartInlineVSCodeServeWeb() -> Bool {
        guard let vscodeApplicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL() else {
            return false
        }
        VSCodeServeWebController.shared.restart(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            if serveWebURL == nil {
                NSSound.beep()
            }
        }
        return true
    }

    private func focusedTerminalDirectoryURL() -> URL? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let rawDirectory: String = {
            if let focusedPanelId = workspace.focusedPanelId,
               let directory = workspace.panelDirectories[focusedPanelId] {
                return directory
            }
            return workspace.currentDirectory
        }()
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

#if DEBUG
    private func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private func debugShortWorkspaceIds(_ ids: [UUID]) -> String {
        if ids.isEmpty { return "[]" }
        return "[" + ids.map { String($0.uuidString.prefix(5)) }.joined(separator: ",") + "]"
    }

    private func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif
}

struct CommandPaletteSwitcherSearchMetadata: Equatable, Sendable {
    let directories: [String]
    let branches: [String]
    let ports: [Int]
    let description: String?

    init(
        directories: [String] = [],
        branches: [String] = [],
        ports: [Int] = [],
        description: String? = nil
    ) {
        self.directories = directories
        self.branches = branches
        self.ports = ports
        self.description = description
    }
}

enum CommandPaletteSwitcherSearchIndexer {
    enum MetadataDetail {
        case workspace
        case surface
    }

    private static let metadataDelimiters = CharacterSet(charactersIn: "/\\.:_- ")

    static func keywords(
        baseKeywords: [String],
        metadata: CommandPaletteSwitcherSearchMetadata,
        detail: MetadataDetail = .surface
    ) -> [String] {
        let metadataKeywords = metadataKeywordsForSearch(metadata, detail: detail)
        return uniqueNormalizedPreservingOrder(baseKeywords + metadataKeywords)
    }

    private static func metadataKeywordsForSearch(
        _ metadata: CommandPaletteSwitcherSearchMetadata,
        detail: MetadataDetail
    ) -> [String] {
        let directoryTokens = metadata.directories.flatMap { directoryTokensForSearch($0, detail: detail) }
        let branchTokens = metadata.branches.flatMap { branchTokensForSearch($0, detail: detail) }
        let portTokens = metadata.ports.flatMap(portTokensForSearch)
        let descriptionTokens = descriptionTokensForSearch(metadata.description)

        var contextKeywords: [String] = []
        if !directoryTokens.isEmpty {
            contextKeywords.append(contentsOf: ["directory", "dir", "cwd", "path"])
        }
        if !branchTokens.isEmpty {
            contextKeywords.append(contentsOf: ["branch", "git"])
        }
        if !portTokens.isEmpty {
            contextKeywords.append(contentsOf: ["port", "ports"])
        }
        if !descriptionTokens.isEmpty {
            contextKeywords.append(contentsOf: ["description", "descriptions", "notes", "note"])
        }

        return contextKeywords + directoryTokens + branchTokens + portTokens + descriptionTokens
    }

    private static func directoryTokensForSearch(
        _ rawDirectory: String,
        detail: MetadataDetail
    ) -> [String] {
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let standardized = (trimmed as NSString).standardizingPath
        let canonical = standardized.isEmpty ? trimmed : standardized
        let abbreviated = (canonical as NSString).abbreviatingWithTildeInPath
        switch detail {
        case .workspace:
            return uniqueNormalizedPreservingOrder([trimmed, canonical, abbreviated])
        case .surface:
            let basename = URL(fileURLWithPath: canonical, isDirectory: true).lastPathComponent
            let components = canonical.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
            return uniqueNormalizedPreservingOrder(
                [trimmed, canonical, abbreviated, basename] + components
            )
        }
    }

    private static func branchTokensForSearch(
        _ rawBranch: String,
        detail: MetadataDetail
    ) -> [String] {
        let trimmed = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        switch detail {
        case .workspace:
            return [trimmed]
        case .surface:
            let components = trimmed.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
            return uniqueNormalizedPreservingOrder([trimmed] + components)
        }
    }

    private static func portTokensForSearch(_ port: Int) -> [String] {
        guard (1...65535).contains(port) else { return [] }
        let portText = String(port)
        return [portText, ":\(portText)"]
    }

    private static func descriptionTokensForSearch(_ rawDescription: String?) -> [String] {
        let trimmed = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return [] }
        let normalizedWhitespace = trimmed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        let components = normalizedWhitespace.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
        return uniqueNormalizedPreservingOrder([trimmed, normalizedWhitespace] + components)
    }

    private static func uniqueNormalizedPreservingOrder(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        result.reserveCapacity(values.count)

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalizedKey = trimmed
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            guard seen.insert(normalizedKey).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

enum CommandPaletteFuzzyMatcher {
    private static let tokenBoundaryChars: Set<Character> = [" ", "-", "_", "/", ".", ":"]

    private enum SingleEditWordPrefixEditKind {
        case candidateExtraCharacter
        case tokenExtraCharacter
        case substitutedCharacter
        case transposedCharacters

        var basePenalty: Int {
            switch self {
            case .candidateExtraCharacter:
                return 0
            case .tokenExtraCharacter:
                return 10
            case .transposedCharacters:
                return 24
            case .substitutedCharacter:
                return 40
            }
        }
    }

    private struct SingleEditWordPrefixMatch {
        let matchedIndices: Set<Int>
        let segmentStart: Int
        let segmentLength: Int
        let prefixLength: Int
        let editPosition: Int
        let editKind: SingleEditWordPrefixEditKind
    }

    struct PreparedQuery {
        let normalizedText: String
        let tokens: [String]

        var isEmpty: Bool {
            tokens.isEmpty
        }
    }

    static func preparedQuery(_ query: String) -> PreparedQuery {
        let normalizedQuery = normalizeForSearch(query)
        return PreparedQuery(
            normalizedText: normalizedQuery,
            tokens: normalizedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        )
    }

    static func normalizeForSearch(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    static func score(query: String, candidate: String) -> Int? {
        score(query: query, candidates: [candidate])
    }

    static func score(query: String, candidates: [String]) -> Int? {
        score(
            preparedQuery: preparedQuery(query),
            normalizedCandidates: candidates
                .map(normalizeForSearch)
                .filter { !$0.isEmpty }
        )
    }

    static func score(preparedQuery: PreparedQuery, normalizedCandidates: [String]) -> Int? {
        guard !preparedQuery.isEmpty else { return 0 }
        guard !normalizedCandidates.isEmpty else { return nil }

        var totalScore = 0
        for token in preparedQuery.tokens {
            var bestTokenScore: Int?
            for candidate in normalizedCandidates {
                guard let candidateScore = scoreToken(token, in: candidate) else { continue }
                bestTokenScore = max(bestTokenScore ?? candidateScore, candidateScore)
            }
            guard let bestTokenScore else { return nil }
            totalScore += bestTokenScore
        }
        return totalScore
    }

    static func matchCharacterIndices(query: String, candidate: String) -> Set<Int> {
        matchCharacterIndices(preparedQuery: preparedQuery(query), candidate: candidate)
    }

    static func matchCharacterIndices(preparedQuery: PreparedQuery, candidate: String) -> Set<Int> {
        guard !preparedQuery.isEmpty else { return [] }

        let loweredCandidate = normalizeForSearch(candidate)
        guard !loweredCandidate.isEmpty else { return [] }

        let candidateChars = Array(loweredCandidate)
        var matched: Set<Int> = []

        for token in preparedQuery.tokens {
            if token == loweredCandidate {
                matched.formUnion(0..<candidateChars.count)
                continue
            }

            if loweredCandidate.hasPrefix(token) {
                matched.formUnion(0..<min(token.count, candidateChars.count))
                continue
            }

            if let range = loweredCandidate.range(of: token) {
                let start = loweredCandidate.distance(from: loweredCandidate.startIndex, to: range.lowerBound)
                let end = min(candidateChars.count, start + token.count)
                matched.formUnion(start..<end)
                continue
            }

            if let singleEditPrefix = singleEditWordPrefixMatch(token: token, candidate: loweredCandidate) {
                matched.formUnion(singleEditPrefix.matchedIndices)
                continue
            }

            if let initialism = initialismMatchIndices(token: token, candidate: loweredCandidate) {
                matched.formUnion(initialism)
                continue
            }

            if let stitched = stitchedWordPrefixMatchIndices(token: token, candidate: loweredCandidate) {
                matched.formUnion(stitched)
                continue
            }

            guard token.count <= 3 else { continue }
            if let subsequence = subsequenceMatchIndices(token: token, candidate: loweredCandidate) {
                matched.formUnion(subsequence)
            }
        }

        return matched
    }

    private static func scoreToken(_ token: String, in candidate: String) -> Int? {
        guard !token.isEmpty else { return 0 }

        let candidateChars = Array(candidate)
        let tokenChars = Array(token)
        guard tokenChars.count <= candidateChars.count else { return nil }

        if token == candidate {
            return 8000
        }
        if candidate.hasPrefix(token) {
            return 6800 - max(0, candidate.count - token.count)
        }

        var bestScore: Int?
        if let wordExactScore = bestWordScore(tokenChars: tokenChars, candidateChars: candidateChars, requireExactWord: true) {
            bestScore = max(bestScore ?? wordExactScore, wordExactScore)
        }
        if let wordPrefixScore = bestWordScore(tokenChars: tokenChars, candidateChars: candidateChars, requireExactWord: false) {
            bestScore = max(bestScore ?? wordPrefixScore, wordPrefixScore)
        }
        if let singleEditPrefixScore = singleEditWordPrefixScore(
            tokenChars: tokenChars,
            candidateChars: candidateChars
        ) {
            bestScore = max(bestScore ?? singleEditPrefixScore, singleEditPrefixScore)
        }

        if let range = candidate.range(of: token) {
            let distance = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            let lengthPenalty = max(0, candidate.count - token.count)
            let boundaryBoost: Int = {
                guard distance > 0 else { return 220 }
                let prior = candidateChars[distance - 1]
                return tokenBoundaryChars.contains(prior) ? 180 : 0
            }()
            let containsScore = 4200 + boundaryBoost - (distance * 9) - lengthPenalty
            bestScore = max(bestScore ?? containsScore, containsScore)
        }

        if let initialismScore = initialismScore(tokenChars: tokenChars, candidateChars: candidateChars) {
            bestScore = max(bestScore ?? initialismScore, initialismScore)
        }

        if let stitchedScore = stitchedWordPrefixScore(tokenChars: tokenChars, candidateChars: candidateChars) {
            bestScore = max(bestScore ?? stitchedScore, stitchedScore)
        }

        if tokenChars.count <= 3, let subsequence = subsequenceScore(token: token, candidate: candidate) {
            bestScore = max(bestScore ?? subsequence, subsequence)
        }

        guard let bestScore else { return nil }
        return max(1, bestScore)
    }

    private static func bestWordScore(
        tokenChars: [Character],
        candidateChars: [Character],
        requireExactWord: Bool
    ) -> Int? {
        guard !tokenChars.isEmpty else { return nil }

        var best: Int?
        for segment in wordSegments(candidateChars) {
            let wordLength = segment.end - segment.start
            guard tokenChars.count <= wordLength else { continue }

            var matchesPrefix = true
            for offset in 0..<tokenChars.count where candidateChars[segment.start + offset] != tokenChars[offset] {
                matchesPrefix = false
                break
            }
            guard matchesPrefix else { continue }
            if requireExactWord && tokenChars.count != wordLength { continue }

            let lengthPenalty = max(0, wordLength - tokenChars.count) * 6
            let distancePenalty = segment.start * 8
            let trailingPenalty = max(0, candidateChars.count - wordLength)
            let scoreBase = requireExactWord ? 6200 : 5600
            let score = scoreBase - distancePenalty - lengthPenalty - trailingPenalty
            best = max(best ?? score, score)
        }

        return best
    }

    private static func singleEditWordPrefixScore(
        tokenChars: [Character],
        candidateChars: [Character]
    ) -> Int? {
        guard let match = singleEditWordPrefixMatch(
            tokenChars: tokenChars,
            candidateChars: candidateChars
        ) else {
            return nil
        }
        return singleEditWordPrefixScore(match: match, candidateLength: candidateChars.count)
    }

    private static func singleEditWordPrefixScore(
        match: SingleEditWordPrefixMatch,
        candidateLength: Int
    ) -> Int {
        let lengthPenalty = max(0, match.segmentLength - match.prefixLength) * 6
        let distancePenalty = match.segmentStart * 8
        let trailingPenalty = max(0, candidateLength - match.segmentLength)
        let editPositionPenalty = max(0, match.editPosition - match.segmentStart) * 10
        return 5000
            - match.editKind.basePenalty
            - distancePenalty
            - lengthPenalty
            - trailingPenalty
            - editPositionPenalty
    }

    private static func initialismScore(tokenChars: [Character], candidateChars: [Character]) -> Int? {
        guard !tokenChars.isEmpty else { return nil }
        let segments = wordSegments(candidateChars)
        guard tokenChars.count <= segments.count else { return nil }

        var matchedStarts: [Int] = []
        var searchWordIndex = 0

        for tokenChar in tokenChars {
            var found = false
            while searchWordIndex < segments.count {
                let segment = segments[searchWordIndex]
                searchWordIndex += 1
                if candidateChars[segment.start] == tokenChar {
                    matchedStarts.append(segment.start)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }

        let firstStart = matchedStarts.first ?? 0
        let skippedWords = max(0, segments.count - tokenChars.count)
        return 3000 + (tokenChars.count * 160) - (firstStart * 5) - (skippedWords * 30)
    }

    private static func tokenPrefixMatches(
        tokenChars: [Character],
        tokenStart: Int,
        length: Int,
        candidateChars: [Character],
        candidateStart: Int
    ) -> Bool {
        guard length >= 0 else { return false }
        guard tokenStart + length <= tokenChars.count else { return false }
        guard candidateStart + length <= candidateChars.count else { return false }
        guard length > 0 else { return true }

        for offset in 0..<length where tokenChars[tokenStart + offset] != candidateChars[candidateStart + offset] {
            return false
        }
        return true
    }

    private static func stitchedWordPrefixScore(tokenChars: [Character], candidateChars: [Character]) -> Int? {
        guard tokenChars.count >= 4 else { return nil }
        let segments = wordSegments(candidateChars)
        guard segments.count >= 2 else { return nil }

        struct StitchState: Hashable {
            let tokenIndex: Int
            let wordIndex: Int
            let usedWords: Int
        }

        var memo: [StitchState: Int?] = [:]

        func dfs(tokenIndex: Int, wordIndex: Int, usedWords: Int) -> Int? {
            if tokenIndex == tokenChars.count {
                return usedWords >= 2 ? 0 : nil
            }
            guard wordIndex < segments.count else { return nil }

            let state = StitchState(tokenIndex: tokenIndex, wordIndex: wordIndex, usedWords: usedWords)
            if let cached = memo[state] {
                return cached
            }

            var best: Int?
            let remainingChars = tokenChars.count - tokenIndex
            for segmentIndex in wordIndex..<segments.count {
                let segment = segments[segmentIndex]
                let segmentLength = segment.end - segment.start
                let maxChunk = min(segmentLength, remainingChars)
                guard maxChunk > 0 else { continue }

                let skippedWords = max(0, segmentIndex - wordIndex)
                let skipPenalty = skippedWords * 120
                for chunkLength in stride(from: maxChunk, through: 1, by: -1) {
                    guard tokenPrefixMatches(
                        tokenChars: tokenChars,
                        tokenStart: tokenIndex,
                        length: chunkLength,
                        candidateChars: candidateChars,
                        candidateStart: segment.start
                    ) else {
                        continue
                    }
                    guard let suffixScore = dfs(
                        tokenIndex: tokenIndex + chunkLength,
                        wordIndex: segmentIndex + 1,
                        usedWords: min(2, usedWords + 1)
                    ) else {
                        continue
                    }

                    let chunkCoverage = chunkLength * 220
                    let contiguityBonus = segmentIndex == wordIndex ? 80 : 0
                    let segmentRemainderPenalty = max(0, segmentLength - chunkLength) * 9
                    let distancePenalty = segment.start * 4
                    let chunkScore = chunkCoverage + contiguityBonus - segmentRemainderPenalty - distancePenalty - skipPenalty
                    let totalScore = suffixScore + chunkScore
                    best = max(best ?? totalScore, totalScore)
                }
            }

            memo[state] = best
            return best
        }

        guard let stitchedScore = dfs(tokenIndex: 0, wordIndex: 0, usedWords: 0) else { return nil }
        let lengthPenalty = max(0, candidateChars.count - tokenChars.count)
        return 3500 + stitchedScore - lengthPenalty
    }

    private static func stitchedWordPrefixMatchIndices(token: String, candidate: String) -> Set<Int>? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard tokenChars.count >= 4 else { return nil }

        let segments = wordSegments(candidateChars)
        guard segments.count >= 2 else { return nil }

        var tokenIndex = 0
        var nextWordIndex = 0
        var usedWords = 0
        var matchedIndices: Set<Int> = []

        while tokenIndex < tokenChars.count {
            let remainingChars = tokenChars.count - tokenIndex
            var foundMatch = false

            for segmentIndex in nextWordIndex..<segments.count {
                let segment = segments[segmentIndex]
                let segmentLength = segment.end - segment.start
                let maxChunk = min(segmentLength, remainingChars)
                guard maxChunk > 0 else { continue }

                for chunkLength in stride(from: maxChunk, through: 1, by: -1) {
                    guard tokenPrefixMatches(
                        tokenChars: tokenChars,
                        tokenStart: tokenIndex,
                        length: chunkLength,
                        candidateChars: candidateChars,
                        candidateStart: segment.start
                    ) else {
                        continue
                    }

                    matchedIndices.formUnion(segment.start..<(segment.start + chunkLength))
                    tokenIndex += chunkLength
                    nextWordIndex = segmentIndex + 1
                    usedWords += 1
                    foundMatch = true
                    break
                }

                if foundMatch { break }
            }

            if !foundMatch { return nil }
        }

        guard usedWords >= 2 else { return nil }
        return matchedIndices
    }

    private static func singleEditWordPrefixMatch(
        token: String,
        candidate: String
    ) -> SingleEditWordPrefixMatch? {
        singleEditWordPrefixMatch(
            tokenChars: Array(token),
            candidateChars: Array(candidate)
        )
    }

    private static func singleEditWordPrefixMatch(
        tokenChars: [Character],
        candidateChars: [Character]
    ) -> SingleEditWordPrefixMatch? {
        guard tokenChars.count >= 4 else { return nil }

        var bestMatch: SingleEditWordPrefixMatch?
        var bestScore: Int?

        for segment in wordSegments(candidateChars) {
            guard let match = singleEditWordPrefixMatch(
                tokenChars: tokenChars,
                candidateChars: candidateChars,
                segment: segment
            ) else {
                continue
            }

            let score = singleEditWordPrefixScore(match: match, candidateLength: candidateChars.count)
            if let bestScore, score <= bestScore {
                continue
            }
            bestScore = score
            bestMatch = match
        }

        return bestMatch
    }

    private static func singleEditWordPrefixMatch(
        tokenChars: [Character],
        candidateChars: [Character],
        segment: (start: Int, end: Int)
    ) -> SingleEditWordPrefixMatch? {
        guard tokenChars.count >= 4 else { return nil }

        let segmentLength = segment.end - segment.start
        guard segmentLength + 1 >= tokenChars.count else { return nil }

        let exactPrefixLength = min(tokenChars.count, segmentLength)
        var mismatchOffset = 0
        while mismatchOffset < exactPrefixLength,
            candidateChars[segment.start + mismatchOffset] == tokenChars[mismatchOffset]
        {
            mismatchOffset += 1
        }

        if mismatchOffset == tokenChars.count {
            let prefixLength = tokenChars.count + 1
            guard segmentLength >= prefixLength else { return nil }
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + tokenChars.count)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: prefixLength,
                editPosition: segment.start + tokenChars.count,
                editKind: .candidateExtraCharacter
            )
        }

        if mismatchOffset == segmentLength {
            let prefixLength = tokenChars.count - 1
            guard prefixLength > 0 else { return nil }
            guard tokenChars.count == segmentLength + 1 else { return nil }
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + prefixLength)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: prefixLength,
                editPosition: segment.start + prefixLength,
                editKind: .tokenExtraCharacter
            )
        }

        let mismatchCandidateIndex = segment.start + mismatchOffset

        if segmentLength >= tokenChars.count + 1,
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset,
                length: tokenChars.count - mismatchOffset,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex + 1
            )
        {
            var matchedIndices = Set(segment.start..<(segment.start + tokenChars.count + 1))
            matchedIndices.remove(mismatchCandidateIndex)
            return SingleEditWordPrefixMatch(
                matchedIndices: matchedIndices,
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count + 1,
                editPosition: mismatchCandidateIndex,
                editKind: .candidateExtraCharacter
            )
        }

        if tokenChars.count >= 2,
            segmentLength >= tokenChars.count - 1,
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset + 1,
                length: tokenChars.count - mismatchOffset - 1,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex
            )
        {
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + tokenChars.count - 1)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count - 1,
                editPosition: mismatchCandidateIndex,
                editKind: .tokenExtraCharacter
            )
        }

        if segmentLength >= tokenChars.count,
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset + 1,
                length: tokenChars.count - mismatchOffset - 1,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex + 1
            )
        {
            var matchedIndices = Set(segment.start..<(segment.start + tokenChars.count))
            matchedIndices.remove(mismatchCandidateIndex)
            return SingleEditWordPrefixMatch(
                matchedIndices: matchedIndices,
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count,
                editPosition: mismatchCandidateIndex,
                editKind: .substitutedCharacter
            )
        }

        if segmentLength >= tokenChars.count,
            mismatchOffset + 1 < tokenChars.count,
            mismatchCandidateIndex + 1 < segment.end,
            tokenChars[mismatchOffset] == candidateChars[mismatchCandidateIndex + 1],
            tokenChars[mismatchOffset + 1] == candidateChars[mismatchCandidateIndex],
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset + 2,
                length: tokenChars.count - mismatchOffset - 2,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex + 2
            )
        {
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + tokenChars.count)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count,
                editPosition: mismatchCandidateIndex,
                editKind: .transposedCharacters
            )
        }

        return nil
    }

    private static func wordSegments(_ candidateChars: [Character]) -> [(start: Int, end: Int)] {
        var segments: [(start: Int, end: Int)] = []
        var index = 0

        while index < candidateChars.count {
            while index < candidateChars.count, tokenBoundaryChars.contains(candidateChars[index]) {
                index += 1
            }
            guard index < candidateChars.count else { break }
            let start = index
            while index < candidateChars.count, !tokenBoundaryChars.contains(candidateChars[index]) {
                index += 1
            }
            segments.append((start: start, end: index))
        }

        return segments
    }

    private static func subsequenceScore(token: String, candidate: String) -> Int? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard tokenChars.count <= candidateChars.count else { return nil }

        var searchIndex = 0
        var previousMatch = -1
        var consecutiveRun = 0
        var score = 0

        for tokenChar in tokenChars {
            var foundIndex: Int?
            while searchIndex < candidateChars.count {
                if candidateChars[searchIndex] == tokenChar {
                    foundIndex = searchIndex
                    break
                }
                searchIndex += 1
            }
            guard let matchedIndex = foundIndex else { return nil }

            score += 90
            if matchedIndex == 0 || tokenBoundaryChars.contains(candidateChars[matchedIndex - 1]) {
                score += 140
            }
            if matchedIndex == previousMatch + 1 {
                consecutiveRun += 1
                score += min(200, consecutiveRun * 45)
            } else {
                consecutiveRun = 0
                score -= min(120, max(0, matchedIndex - previousMatch - 1) * 4)
            }

            previousMatch = matchedIndex
            searchIndex = matchedIndex + 1
        }

        score -= max(0, candidateChars.count - tokenChars.count)
        return max(1, score)
    }

    private static func subsequenceMatchIndices(token: String, candidate: String) -> Set<Int>? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard tokenChars.count <= candidateChars.count else { return nil }

        var indices: Set<Int> = []
        var searchIndex = 0

        for tokenChar in tokenChars {
            var foundIndex: Int?
            while searchIndex < candidateChars.count {
                if candidateChars[searchIndex] == tokenChar {
                    foundIndex = searchIndex
                    break
                }
                searchIndex += 1
            }
            guard let matchIndex = foundIndex else { return nil }
            indices.insert(matchIndex)
            searchIndex = matchIndex + 1
        }

        return indices
    }

    private static func initialismMatchIndices(token: String, candidate: String) -> Set<Int>? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard !tokenChars.isEmpty else { return nil }

        let segments = wordSegments(candidateChars)
        guard tokenChars.count <= segments.count else { return nil }

        var matched: Set<Int> = []
        var searchWordIndex = 0

        for tokenChar in tokenChars {
            var found = false
            while searchWordIndex < segments.count {
                let segment = segments[searchWordIndex]
                searchWordIndex += 1
                if candidateChars[segment.start] == tokenChar {
                    matched.insert(segment.start)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }

        return matched
    }
}

struct CommandPaletteSearchCorpusEntry<Payload>: Sendable where Payload: Sendable {
    let payload: Payload
    let rank: Int
    let title: String
    let normalizedTitle: String
    let normalizedSearchableTexts: [String]

    init(payload: Payload, rank: Int, title: String, searchableTexts: [String]) {
        self.payload = payload
        self.rank = rank
        self.title = title
        self.normalizedTitle = CommandPaletteFuzzyMatcher.normalizeForSearch(title)
        self.normalizedSearchableTexts = searchableTexts
            .map(CommandPaletteFuzzyMatcher.normalizeForSearch)
            .filter { !$0.isEmpty }
    }
}

struct CommandPaletteSearchCorpusResult<Payload>: Sendable where Payload: Sendable {
    let payload: Payload
    let rank: Int
    let title: String
    let score: Int
    let titleMatchIndices: Set<Int>
}

enum CommandPaletteSearchEngine {
    private static let titleMatchBonus = 2000

    static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        historyBoost: (Payload, Bool) -> Int
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            historyBoost: historyBoost,
            shouldCancel: nil
        )
    }

    static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: @escaping () -> Bool
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            historyBoost: historyBoost,
            shouldCancel: Optional(shouldCancel)
        )
    }

    private static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: (() -> Bool)?
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let queryIsEmpty = preparedQuery.isEmpty
        var results: [CommandPaletteSearchCorpusResult<Payload>] = []
        results.reserveCapacity(entries.count)

        func shouldCancelSearch(at index: Int) -> Bool {
            guard let shouldCancel else { return false }
            return index % 16 == 0 && shouldCancel()
        }

        if queryIsEmpty {
            for (index, entry) in entries.enumerated() {
                if shouldCancelSearch(at: index) { return [] }
                results.append(
                    CommandPaletteSearchCorpusResult(
                    payload: entry.payload,
                    rank: entry.rank,
                    title: entry.title,
                    score: historyBoost(entry.payload, true),
                    titleMatchIndices: []
                )
                )
            }
        } else {
            for (index, entry) in entries.enumerated() {
                if shouldCancelSearch(at: index) { return [] }
                guard let fuzzyScore = weightedScore(
                    preparedQuery: preparedQuery,
                    entry: entry
                ) else {
                    continue
                }
                results.append(
                    CommandPaletteSearchCorpusResult(
                        payload: entry.payload,
                        rank: entry.rank,
                        title: entry.title,
                        score: fuzzyScore + historyBoost(entry.payload, false),
                        titleMatchIndices: CommandPaletteFuzzyMatcher.matchCharacterIndices(
                            preparedQuery: preparedQuery,
                            candidate: entry.title
                        )
                    )
                )
            }
        }

        if shouldCancel?() == true { return [] }

        return results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func weightedScore<Payload: Sendable>(
        preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery,
        entry: CommandPaletteSearchCorpusEntry<Payload>
    ) -> Int? {
        guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(
                    preparedQuery: preparedQuery,
                    normalizedCandidates: entry.normalizedSearchableTexts
                ) else {
            return nil
        }
        guard !entry.normalizedTitle.isEmpty,
              let titleScore = CommandPaletteFuzzyMatcher.score(
                preparedQuery: preparedQuery,
                normalizedCandidates: [entry.normalizedTitle]
              ) else {
            return fuzzyScore
        }
        return max(fuzzyScore, titleScore + titleMatchBonus)
    }
}

private struct SidebarResizerAccessibilityModifier: ViewModifier {
    let accessibilityIdentifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let accessibilityIdentifier {
            content.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }
}

private struct SidebarTabItemSettingsSnapshot: Equatable {
    let sidebarShortcutHintXOffset: Double
    let sidebarShortcutHintYOffset: Double
    let alwaysShowShortcutHints: Bool
    let showsGitBranch: Bool
    let usesVerticalBranchLayout: Bool
    let showsGitBranchIcon: Bool
    let showsSSH: Bool
    let openPullRequestLinksInCmuxBrowser: Bool
    let openPortLinksInCmuxBrowser: Bool
    let showsNotificationMessage: Bool
    let activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle
    let selectionColorHex: String?
    let notificationBadgeColorHex: String?
    let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility

    init(defaults: UserDefaults = .standard) {
        sidebarShortcutHintXOffset = Self.double(
            defaults: defaults,
            key: ShortcutHintDebugSettings.sidebarHintXKey,
            defaultValue: ShortcutHintDebugSettings.defaultSidebarHintX
        )
        sidebarShortcutHintYOffset = Self.double(
            defaults: defaults,
            key: ShortcutHintDebugSettings.sidebarHintYKey,
            defaultValue: ShortcutHintDebugSettings.defaultSidebarHintY
        )
        alwaysShowShortcutHints = Self.bool(
            defaults: defaults,
            key: ShortcutHintDebugSettings.alwaysShowHintsKey,
            defaultValue: ShortcutHintDebugSettings.defaultAlwaysShowHints
        )
        showsGitBranch = Self.bool(defaults: defaults, key: "sidebarShowGitBranch", defaultValue: true)
        usesVerticalBranchLayout = SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults)
        showsGitBranchIcon = Self.bool(defaults: defaults, key: "sidebarShowGitBranchIcon", defaultValue: false)
        showsSSH = Self.bool(defaults: defaults, key: "sidebarShowSSH", defaultValue: true)
        openPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(
            defaults: defaults
        )
        openPortLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowser(
            defaults: defaults
        )

        let hidesAllDetails = SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
        let showsNotificationMessageSetting = SidebarWorkspaceDetailSettings.showsNotificationMessage(
            defaults: defaults
        )
        showsNotificationMessage = SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
            showNotificationMessage: showsNotificationMessageSetting,
            hideAllDetails: hidesAllDetails
        )

        let showsMetadata = Self.bool(defaults: defaults, key: "sidebarShowStatusPills", defaultValue: true)
        let showsLog = Self.bool(defaults: defaults, key: "sidebarShowLog", defaultValue: true)
        let showsProgress = Self.bool(defaults: defaults, key: "sidebarShowProgress", defaultValue: true)
        let showsBranchDirectory = Self.bool(defaults: defaults, key: "sidebarShowBranchDirectory", defaultValue: true)
        let showsPullRequests = Self.bool(defaults: defaults, key: "sidebarShowPullRequest", defaultValue: true)
        let showsPorts = Self.bool(defaults: defaults, key: "sidebarShowPorts", defaultValue: true)
        visibleAuxiliaryDetails = SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
            showMetadata: showsMetadata,
            showLog: showsLog,
            showProgress: showsProgress,
            showBranchDirectory: showsBranchDirectory,
            showPullRequests: showsPullRequests,
            showPorts: showsPorts,
            hideAllDetails: hidesAllDetails
        )

        activeTabIndicatorStyle = SidebarActiveTabIndicatorSettings.current(defaults: defaults)
        selectionColorHex = defaults.string(forKey: "sidebarSelectionColorHex")
        notificationBadgeColorHex = defaults.string(forKey: "sidebarNotificationBadgeColorHex")
    }

    private static func bool(
        defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func double(
        defaults: UserDefaults,
        key: String,
        defaultValue: Double
    ) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return defaultValue }
        return value.doubleValue
    }
}

@MainActor
private final class SidebarTabItemSettingsStore: ObservableObject {
    @Published private(set) var snapshot: SidebarTabItemSettingsSnapshot

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func refreshSnapshot() {
        let nextSnapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }
}

private struct SidebarTabItemPresentationSnapshot: Equatable {
    let tabId: UUID
    let unreadCount: Int
    let latestNotificationText: String?
    let showsModifierShortcutHints: Bool
}

struct VerticalTabsSidebar: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @StateObject private var modifierKeyMonitor = SidebarShortcutHintModifierMonitor()
    @StateObject private var dragAutoScrollController = SidebarDragAutoScrollController()
    @StateObject private var dragFailsafeMonitor = SidebarDragFailsafeMonitor()
    @StateObject private var tabItemSettingsStore = SidebarTabItemSettingsStore()
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var draggedTabId: UUID?
    @State private var dropIndicator: SidebarDropIndicator?
    @State private var frozenTabItemPresentation: SidebarTabItemPresentationSnapshot?
    @State private var terminalScrollBarVisibilityGeneration: UInt64 = 0
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    /// Space at top of sidebar for traffic light buttons
    private let trafficLightPadding: CGFloat = 28
    private let tabRowSpacing: CGFloat = 2
    private let hiddenTitlebarControlsLeadingInset: CGFloat = 72

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var showsSidebarNotificationMessage: Bool {
        tabItemSettingsStore.snapshot.showsNotificationMessage
    }

    private var workspaceNumberShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
    }

    var body: some View {
        let _ = terminalScrollBarVisibilityGeneration
        let tabs = tabManager.tabs
        let workspaceCount = tabs.count
        let canCloseWorkspace = workspaceCount > 1
        let workspaceNumberShortcut = self.workspaceNumberShortcut
        let tabItemSettings = tabItemSettingsStore.snapshot
        let tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let orderedSelectedTabs = tabs.filter { selectedTabIds.contains($0.id) }
        let selectedContextTargetIds = orderedSelectedTabs.map(\.id)
        let selectedRemoteContextMenuTargets = orderedSelectedTabs.filter { $0.isRemoteWorkspace }
        let selectedRemoteContextMenuWorkspaceIds = selectedRemoteContextMenuTargets.map(\.id)
        let workspaceTerminalScrollBarHiddenById = Dictionary(
            uniqueKeysWithValues: tabs.map { ($0.id, $0.terminalScrollBarHidden) }
        )
        let allSelectedRemoteContextMenuTargetsConnecting = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .connecting }
        let allSelectedRemoteContextMenuTargetsDisconnected = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .disconnected }

        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Space for traffic lights / fullscreen controls
                        Spacer()
                            .frame(height: trafficLightPadding)

                        // Workspaces are bounded, so prefer a non-lazy stack here.
                        // LazyVStack + drag-state invalidations can recurse through layout.
                        VStack(spacing: tabRowSpacing) {
                            ForEach(tabs, id: \.id) { tab in
                                let index = tabIndexById[tab.id] ?? 0
                                let usesSelectedContextMenuTargets = selectedTabIds.contains(tab.id)
                                let contextMenuWorkspaceIds = usesSelectedContextMenuTargets
                                    ? selectedContextTargetIds
                                    : [tab.id]
                                let remoteContextMenuWorkspaceIds = usesSelectedContextMenuTargets
                                    ? selectedRemoteContextMenuWorkspaceIds
                                    : (tab.isRemoteWorkspace ? [tab.id] : [])
                                let allRemoteContextMenuTargetsConnecting = usesSelectedContextMenuTargets
                                    ? allSelectedRemoteContextMenuTargetsConnecting
                                    : (tab.isRemoteWorkspace && tab.remoteConnectionState == .connecting)
                                let allRemoteContextMenuTargetsDisconnected = usesSelectedContextMenuTargets
                                    ? allSelectedRemoteContextMenuTargetsDisconnected
                                    : (tab.isRemoteWorkspace && tab.remoteConnectionState == .disconnected)
                                let allContextMenuWorkspacesHideTerminalScrollBar = !contextMenuWorkspaceIds.isEmpty &&
                                    contextMenuWorkspaceIds.allSatisfy { workspaceId in
                                        workspaceTerminalScrollBarHiddenById[workspaceId] == true
                                    }
                                let liveUnreadCount = notificationStore.unreadCount(forTabId: tab.id)
                                let liveLatestNotificationText: String? = {
                                    guard showsSidebarNotificationMessage,
                                          let notification = notificationStore.latestNotification(forTabId: tab.id) else {
                                        return nil
                                    }
                                    let text = notification.body.isEmpty ? notification.title : notification.body
                                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    return trimmed.isEmpty ? nil : trimmed
                                }()
                                let liveShowsModifierShortcutHints = modifierKeyMonitor.isModifierPressed
                                let livePresentation = SidebarTabItemPresentationSnapshot(
                                    tabId: tab.id,
                                    unreadCount: liveUnreadCount,
                                    latestNotificationText: liveLatestNotificationText,
                                    showsModifierShortcutHints: liveShowsModifierShortcutHints
                                )
                                let frozenPresentation = frozenTabItemPresentation?.tabId == tab.id
                                    ? frozenTabItemPresentation
                                    : nil
                                TabItemView(
                                    tabManager: tabManager,
                                    notificationStore: notificationStore,
                                    tab: tab,
                                    index: index,
                                    isActive: tabManager.selectedTabId == tab.id,
                                    workspaceShortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
                                        at: index,
                                        workspaceCount: workspaceCount
                                    ),
                                    workspaceShortcutModifierSymbol: workspaceNumberShortcut.numberedDigitHintPrefix,
                                    canCloseWorkspace: canCloseWorkspace,
                                    accessibilityWorkspaceCount: workspaceCount,
                                    unreadCount: frozenPresentation?.unreadCount ?? liveUnreadCount,
                                    latestNotificationText: frozenPresentation?.latestNotificationText ?? liveLatestNotificationText,
                                    rowSpacing: tabRowSpacing,
                                    setSelectionToTabs: { selection = .tabs },
                                    selectedTabIds: $selectedTabIds,
                                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                                    showsModifierShortcutHints: frozenPresentation?.showsModifierShortcutHints ?? liveShowsModifierShortcutHints,
                                    dragAutoScrollController: dragAutoScrollController,
                                    draggedTabId: $draggedTabId,
                                    dropIndicator: $dropIndicator,
                                    contextMenuWorkspaceIds: contextMenuWorkspaceIds,
                                    remoteContextMenuWorkspaceIds: remoteContextMenuWorkspaceIds,
                                    allRemoteContextMenuTargetsConnecting: allRemoteContextMenuTargetsConnecting,
                                    allRemoteContextMenuTargetsDisconnected: allRemoteContextMenuTargetsDisconnected,
                                    allContextMenuWorkspacesHideTerminalScrollBar: allContextMenuWorkspacesHideTerminalScrollBar,
                                    settings: tabItemSettings,
                                    livePresentation: livePresentation,
                                    frozenPresentation: $frozenTabItemPresentation
                                )
                                .equatable()
                            }
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        SidebarEmptyArea(
                            rowSpacing: tabRowSpacing,
                            selection: $selection,
                            selectedTabIds: $selectedTabIds,
                            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                            dragAutoScrollController: dragAutoScrollController,
                            draggedTabId: $draggedTabId,
                            dropIndicator: $dropIndicator
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .background(
                    SidebarScrollViewResolver { scrollView in
                        dragAutoScrollController.attach(scrollView: scrollView)
                    }
                    .frame(width: 0, height: 0)
                )
                .overlay(alignment: .top) {
                    SidebarTopScrim(height: trafficLightPadding + 20)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .top) {
                    // Match native titlebar behavior in the sidebar top strip:
                    // drag-to-move and double-click action (zoom/minimize).
                    WindowDragHandleView()
                        .frame(height: trafficLightPadding)
                        .background(TitlebarDoubleClickMonitorView())
                }
                .overlay(alignment: .topLeading) {
                    if isMinimalMode {
                        HiddenTitlebarSidebarControlsView(notificationStore: notificationStore)
                            .padding(.leading, hiddenTitlebarControlsLeadingInset)
                            .padding(.top, 2)
                    }
                }
                .background(Color.clear)
                .modifier(ClearScrollBackground())
            }
            SidebarFooter(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("Sidebar")
        .ignoresSafeArea()
        .background(SidebarBackdrop().ignoresSafeArea())
        .overlay(alignment: .trailing) {
            SidebarTrailingBorder()
        }
        .background(
            WindowAccessor { window in
                modifierKeyMonitor.setHostWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            modifierKeyMonitor.start()
            draggedTabId = nil
            dropIndicator = nil
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: nil,
                reason: "sidebar_appear"
            )
        }
        .onDisappear {
            modifierKeyMonitor.stop()
            dragAutoScrollController.stop()
            dragFailsafeMonitor.stop()
            draggedTabId = nil
            dropIndicator = nil
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: nil,
                reason: "sidebar_disappear"
            )
        }
        .onChange(of: draggedTabId) { newDraggedTabId in
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: newDraggedTabId,
                reason: "drag_state_change"
            )
#if DEBUG
            dlog("sidebar.dragState.sidebar tab=\(debugShortSidebarTabId(newDraggedTabId))")
#endif
            if newDraggedTabId != nil {
                dragFailsafeMonitor.start {
                    SidebarDragLifecycleNotification.postClearRequest(reason: $0)
                }
                return
            }
            dragFailsafeMonitor.stop()
            dragAutoScrollController.stop()
            dropIndicator = nil
        }
        .onChange(of: tabs.map(\.id)) { tabIds in
            guard let frozenTabItemPresentation,
                  !tabIds.contains(frozenTabItemPresentation.tabId) else { return }
            self.frozenTabItemPresentation = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.requestClear)) { notification in
            guard draggedTabId != nil else { return }
            let reason = SidebarDragLifecycleNotification.reason(from: notification)
#if DEBUG
            dlog("sidebar.dragClear tab=\(debugShortSidebarTabId(draggedTabId)) reason=\(reason)")
#endif
            draggedTabId = nil
        }
        .onReceive(
            NotificationCenter.default.publisher(for: Workspace.terminalScrollBarHiddenDidChangeNotification)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let workspace = notification.object as? Workspace,
                  tabManager.tabs.contains(where: { $0 === workspace }) else {
                return
            }

            // Workspace scrollbar visibility changes do not publish on TabManager.tabs,
            // so bump a local generation to refresh the precomputed context-menu state.
            terminalScrollBarVisibilityGeneration &+= 1
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

enum ShortcutHintModifierPolicy {
    static let intentionalHoldDelay: TimeInterval = 0.30

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch normalized {
        case [.command]:
            return ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(defaults: defaults)
        case [.control]:
            return ShortcutHintDebugSettings.showHintsOnControlHoldEnabled(defaults: defaults)
        default:
            return false
        }
    }

    static func isCurrentWindow(
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?
    ) -> Bool {
        guard let hostWindowNumber, hostWindowIsKey else { return false }
        if let eventWindowNumber {
            return eventWindowNumber == hostWindowNumber
        }
        return keyWindowNumber == hostWindowNumber
    }

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldShowHints(for: modifierFlags, defaults: defaults) &&
            isCurrentWindow(
                hostWindowNumber: hostWindowNumber,
                hostWindowIsKey: hostWindowIsKey,
                eventWindowNumber: eventWindowNumber,
                keyWindowNumber: keyWindowNumber
            )
    }
}

enum ShortcutHintDebugSettings {
    static let sidebarHintXKey = "shortcutHintSidebarXOffset"
    static let sidebarHintYKey = "shortcutHintSidebarYOffset"
    static let titlebarHintXKey = "shortcutHintTitlebarXOffset"
    static let titlebarHintYKey = "shortcutHintTitlebarYOffset"
    static let paneHintXKey = "shortcutHintPaneTabXOffset"
    static let paneHintYKey = "shortcutHintPaneTabYOffset"
    static let alwaysShowHintsKey = "shortcutHintAlwaysShow"
    static let showHintsOnCommandHoldKey = "shortcutHintShowOnCommandHold"
    static let showHintsOnControlHoldKey = "shortcutHintShowOnControlHold"

    static let defaultSidebarHintX = 0.0
    static let defaultSidebarHintY = 0.0
    static let defaultTitlebarHintX = 4.0
    static let defaultTitlebarHintY = 0.0
    static let defaultPaneHintX = 0.0
    static let defaultPaneHintY = 0.0
    static let defaultAlwaysShowHints = false
    static let defaultShowHintsOnCommandHold = true
    static let defaultShowHintsOnControlHold = true

    static let offsetRange: ClosedRange<Double> = -20...20

    static func clamped(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showHintsOnCommandHoldKey) != nil else {
            return defaultShowHintsOnCommandHold
        }
        return defaults.bool(forKey: showHintsOnCommandHoldKey)
    }

    static func showHintsOnControlHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showHintsOnControlHoldKey) != nil else {
            return defaultShowHintsOnControlHold
        }
        return defaults.bool(forKey: showHintsOnControlHoldKey)
    }

    static func resetVisibilityDefaults(defaults: UserDefaults = .standard) {
        defaults.set(defaultAlwaysShowHints, forKey: alwaysShowHintsKey)
        defaults.set(defaultShowHintsOnCommandHold, forKey: showHintsOnCommandHoldKey)
        defaults.set(defaultShowHintsOnControlHold, forKey: showHintsOnControlHoldKey)
    }
}

enum DevBuildBannerDebugSettings {
    static let sidebarBannerVisibleKey = "showSidebarDevBuildBanner"
    static let defaultShowSidebarBanner = true

    static func showSidebarBanner(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: sidebarBannerVisibleKey) != nil else {
            return defaultShowSidebarBanner
        }
        return defaults.bool(forKey: sidebarBannerVisibleKey)
    }
}

private enum FeedbackComposerSettings {
    static let storedEmailKey = "sidebarHelpFeedbackEmail"
    static let endpointEnvironmentKey = "CMUX_FEEDBACK_API_URL"
    static let defaultEndpoint = "https://cmux.com/api/feedback"
    static let foundersEmail = "founders@manaflow.com"
    static let maxMessageLength = 4_000
    static let maxAttachmentCount = 10
    // Keep the multipart body below Vercel's 4.5 MB request limit.
    static let maxTotalAttachmentBytes = 4 * 1_024 * 1_024
    static let targetTotalAttachmentUploadBytes = 3_500_000

    static func endpointURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env[endpointEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(string: override)
        }
        return URL(string: defaultEndpoint)
    }
}

private struct FeedbackComposerAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let fileSize: Int64
    let mimeType: String

    var standardizedPath: String {
        url.standardizedFileURL.path
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    init(url: URL) throws {
        let resourceValues = try url.resourceValues(forKeys: [
            .contentTypeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .nameKey,
        ])
        guard resourceValues.isRegularFile != false else {
            throw CocoaError(.fileReadUnknown)
        }

        self.url = url
        self.fileName = resourceValues.name ?? url.lastPathComponent
        self.fileSize = Int64(resourceValues.fileSize ?? 0)
        self.mimeType = resourceValues.contentType?.preferredMIMEType ?? "application/octet-stream"
    }
}

private struct PreparedFeedbackComposerAttachment {
    let fileName: String
    let mimeType: String
    let data: Data
}

private struct FeedbackComposerAppMetadata {
    let appVersion: String
    let appBuild: String
    let appCommit: String
    let bundleIdentifier: String
    let osVersion: String
    let localeIdentifier: String
    let hardwareModel: String
    let chip: String
    let memoryGB: String
    let architecture: String
    let displayInfo: String

    static var current: FeedbackComposerAppMetadata {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let commit = (infoDictionary["CMUXCommit"] as? String).flatMap { value in
            value.isEmpty ? nil : value
        } ?? env["CMUX_COMMIT"]

        return FeedbackComposerAppMetadata(
            appVersion: infoDictionary["CFBundleShortVersionString"] as? String ?? "",
            appBuild: infoDictionary["CFBundleVersion"] as? String ?? "",
            appCommit: commit ?? "",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            localeIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier,
            hardwareModel: sysctlString("hw.model") ?? "",
            chip: sysctlString("machdep.cpu.brand_string") ?? "",
            memoryGB: formatMemoryGB(),
            architecture: currentArchitecture(),
            displayInfo: currentDisplayInfo()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatMemoryGB() -> String {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return "\(Int(gb)) GB"
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func currentDisplayInfo() -> String {
        let screens = NSScreen.screens
        let descriptions = screens.map { screen -> String in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            return "\(Int(frame.width))x\(Int(frame.height)) @\(Int(scale))x"
        }
        let count = screens.count
        let prefix = "\(count) display\(count == 1 ? "" : "s")"
        return "\(prefix), \(descriptions.joined(separator: "; "))"
    }
}

private enum FeedbackComposerSubmissionError: Error {
    case invalidEndpoint
    case invalidResponse
    case rejected(statusCode: Int)
    case attachmentReadFailed
    case attachmentPreparationFailed
    case transport(URLError)
}

private enum FeedbackComposerClient {
    private static let passthroughAttachmentMIMETypes: Set<String> = [
        "image/gif",
        "image/heic",
        "image/heif",
        "image/jpeg",
        "image/png",
        "image/tiff",
        "image/webp",
    ]
    private static let optimizedAttachmentDimensions: [Int] = [2800, 2400, 2000, 1600, 1280, 1024, 768, 640, 512]
    private static let optimizedAttachmentQualities: [CGFloat] = [0.82, 0.72, 0.62, 0.52, 0.42, 0.32]
    private static let optimizedAttachmentMIMEType = "image/jpeg"

    static func submit(
        email: String,
        message: String,
        attachments: [FeedbackComposerAttachment]
    ) async throws {
        guard let endpointURL = FeedbackComposerSettings.endpointURL() else {
            throw FeedbackComposerSubmissionError.invalidEndpoint
        }

        let metadata = FeedbackComposerAppMetadata.current
        let boundary = "Boundary-\(UUID().uuidString)"
        let preparedAttachments = try prepareAttachmentsForUpload(attachments)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()
        appendField("email", value: email, to: &body, boundary: boundary)
        appendField("message", value: message, to: &body, boundary: boundary)
        appendField("appVersion", value: metadata.appVersion, to: &body, boundary: boundary)
        appendField("appBuild", value: metadata.appBuild, to: &body, boundary: boundary)
        appendField("appCommit", value: metadata.appCommit, to: &body, boundary: boundary)
        appendField("bundleIdentifier", value: metadata.bundleIdentifier, to: &body, boundary: boundary)
        appendField("osVersion", value: metadata.osVersion, to: &body, boundary: boundary)
        appendField("locale", value: metadata.localeIdentifier, to: &body, boundary: boundary)
        appendField("hardwareModel", value: metadata.hardwareModel, to: &body, boundary: boundary)
        appendField("chip", value: metadata.chip, to: &body, boundary: boundary)
        appendField("memoryGB", value: metadata.memoryGB, to: &body, boundary: boundary)
        appendField("architecture", value: metadata.architecture, to: &body, boundary: boundary)
        appendField("displayInfo", value: metadata.displayInfo, to: &body, boundary: boundary)

        for attachment in preparedAttachments {
            appendFile(
                named: "attachments",
                attachment: attachment,
                to: &body,
                boundary: boundary
            )
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw FeedbackComposerSubmissionError.transport(error)
        } catch {
            throw FeedbackComposerSubmissionError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackComposerSubmissionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = payload["error"] as? String,
               errorMessage.isEmpty == false {
                NSLog("feedback.submit.rejected status=%@ error=%@", String(httpResponse.statusCode), errorMessage)
            }
            throw FeedbackComposerSubmissionError.rejected(statusCode: httpResponse.statusCode)
        }
    }

    private static func appendField(
        _ name: String,
        value: String,
        to body: inout Data,
        boundary: String
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private static func prepareAttachmentsForUpload(
        _ attachments: [FeedbackComposerAttachment]
    ) throws -> [PreparedFeedbackComposerAttachment] {
        guard attachments.isEmpty == false else { return [] }

        struct IndexedAttachment {
            let index: Int
            let attachment: FeedbackComposerAttachment
        }

        let sortedAttachments = attachments.enumerated()
            .map { IndexedAttachment(index: $0.offset, attachment: $0.element) }
            .sorted { lhs, rhs in
                lhs.attachment.fileSize > rhs.attachment.fileSize
            }

        var preparedByIndex: [Int: PreparedFeedbackComposerAttachment] = [:]
        var remainingBudget = FeedbackComposerSettings.targetTotalAttachmentUploadBytes
        var remainingCount = sortedAttachments.count

        for item in sortedAttachments {
            let perAttachmentBudget = max(1, remainingBudget / max(remainingCount, 1))
            let preparedAttachment = try prepareAttachmentForUpload(
                item.attachment,
                maximumByteCount: perAttachmentBudget
            )
            preparedByIndex[item.index] = preparedAttachment
            remainingBudget -= preparedAttachment.data.count
            remainingCount -= 1
        }

        let preparedAttachments = attachments.indices.compactMap { preparedByIndex[$0] }
        let totalBytes = preparedAttachments.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= FeedbackComposerSettings.targetTotalAttachmentUploadBytes else {
            throw FeedbackComposerSubmissionError.attachmentPreparationFailed
        }
        return preparedAttachments
    }

    private static func prepareAttachmentForUpload(
        _ attachment: FeedbackComposerAttachment,
        maximumByteCount: Int
    ) throws -> PreparedFeedbackComposerAttachment {
        if attachment.fileSize > 0,
           attachment.fileSize <= Int64(maximumByteCount),
           passthroughAttachmentMIMETypes.contains(attachment.mimeType),
           let fileData = try? Data(contentsOf: attachment.url, options: .mappedIfSafe) {
            return PreparedFeedbackComposerAttachment(
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                data: fileData
            )
        }

        guard let imageSource = CGImageSourceCreateWithURL(attachment.url as CFURL, nil) else {
            throw FeedbackComposerSubmissionError.attachmentReadFailed
        }

        for maxPixelDimension in optimizedAttachmentDimensions {
            guard let cgImage = downsampledImage(
                from: imageSource,
                maxPixelDimension: maxPixelDimension
            ) else { continue }

            for compressionQuality in optimizedAttachmentQualities {
                guard let jpegData = jpegData(
                    from: cgImage,
                    compressionQuality: compressionQuality
                ) else { continue }
                guard jpegData.count <= maximumByteCount else { continue }

                return PreparedFeedbackComposerAttachment(
                    fileName: optimizedFileName(for: attachment),
                    mimeType: optimizedAttachmentMIMEType,
                    data: jpegData
                )
            }
        }

        throw FeedbackComposerSubmissionError.attachmentPreparationFailed
    }

    private static func downsampledImage(
        from imageSource: CGImageSource,
        maxPixelDimension: Int
    ) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            ] as CFDictionary
        )
    }

    private static func jpegData(
        from image: CGImage,
        compressionQuality: CGFloat
    ) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(
            using: .jpeg,
            properties: [
                .compressionFactor: compressionQuality,
            ]
        )
    }

    private static func optimizedFileName(
        for attachment: FeedbackComposerAttachment
    ) -> String {
        let baseName = (attachment.fileName as NSString).deletingPathExtension
        return "\(baseName.isEmpty ? "feedback-image" : baseName).jpg"
    }

    private static func appendFile(
        named fieldName: String,
        attachment: PreparedFeedbackComposerAttachment,
        to body: inout Data,
        boundary: String
    ) {
        let sanitizedFileName = attachment.fileName.replacingOccurrences(of: "\"", with: "")

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(sanitizedFileName)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(attachment.mimeType)\r\n\r\n".utf8))
        body.append(attachment.data)
        body.append(Data("\r\n".utf8))
    }
}

enum SidebarDragLifecycleNotification {
    static let stateDidChange = Notification.Name("cmux.sidebarDragStateDidChange")
    static let requestClear = Notification.Name("cmux.sidebarDragRequestClear")
    static let tabIdKey = "tabId"
    static let reasonKey = "reason"

    static func postStateDidChange(tabId: UUID?, reason: String) {
        var userInfo: [AnyHashable: Any] = [reasonKey: reason]
        if let tabId {
            userInfo[tabIdKey] = tabId
        }
        NotificationCenter.default.post(
            name: stateDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    static func postClearRequest(reason: String) {
        NotificationCenter.default.post(
            name: requestClear,
            object: nil,
            userInfo: [reasonKey: reason]
        )
    }

    static func tabId(from notification: Notification) -> UUID? {
        notification.userInfo?[tabIdKey] as? UUID
    }

    static func reason(from notification: Notification) -> String {
        notification.userInfo?[reasonKey] as? String ?? "unknown"
    }
}

enum SidebarOutsideDropResetPolicy {
    static func shouldResetDrag(draggedTabId: UUID?, hasSidebarDragPayload: Bool) -> Bool {
        draggedTabId != nil && hasSidebarDragPayload
    }
}

enum SidebarDragFailsafePolicy {
    static let clearDelay: TimeInterval = 0.15

    static func shouldRequestClear(isDragActive: Bool, isLeftMouseButtonDown: Bool) -> Bool {
        isDragActive && !isLeftMouseButtonDown
    }

    static func shouldRequestClearWhenMonitoringStarts(isLeftMouseButtonDown: Bool) -> Bool {
        shouldRequestClear(
            isDragActive: true,
            isLeftMouseButtonDown: isLeftMouseButtonDown
        )
    }

    static func shouldRequestClear(forMouseEventType eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseUp
    }
}

@MainActor
private final class SidebarDragFailsafeMonitor: ObservableObject {
    private static let escapeKeyCode: UInt16 = 53
    private var pendingClearWorkItem: DispatchWorkItem?
    private var appResignObserver: NSObjectProtocol?
    private var keyDownMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var onRequestClear: ((String) -> Void)?

    func start(onRequestClear: @escaping (String) -> Void) {
        self.onRequestClear = onRequestClear
        if SidebarDragFailsafePolicy.shouldRequestClearWhenMonitoringStarts(
            isLeftMouseButtonDown: CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            )
        ) {
            requestClearSoon(reason: "mouse_up_failsafe")
        }
        if appResignObserver == nil {
            appResignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "app_resign_active")
                }
            }
        }
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == Self.escapeKeyCode {
                    self?.requestClearSoon(reason: "escape_cancel")
                }
                return event
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if SidebarDragFailsafePolicy.shouldRequestClear(forMouseEventType: event.type) {
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard SidebarDragFailsafePolicy.shouldRequestClear(forMouseEventType: event.type) else { return }
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
            }
        }
    }

    func stop() {
        pendingClearWorkItem?.cancel()
        pendingClearWorkItem = nil
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        onRequestClear = nil
    }

    private func requestClearSoon(reason: String) {
        guard pendingClearWorkItem == nil else { return }
#if DEBUG
        dlog("sidebar.dragFailsafe.schedule reason=\(reason)")
#endif
        let workItem = DispatchWorkItem { [weak self] in
#if DEBUG
            dlog("sidebar.dragFailsafe.fire reason=\(reason)")
#endif
            self?.pendingClearWorkItem = nil
            self?.onRequestClear?(reason)
        }
        pendingClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarDragFailsafePolicy.clearDelay, execute: workItem)
    }
}

private struct SidebarExternalDropOverlay: View {
    let draggedTabId: UUID?

    var body: some View {
        let dragPasteboardTypes = NSPasteboard(name: .drag).types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
            draggedTabId: draggedTabId,
            pasteboardTypes: dragPasteboardTypes
        )
        Group {
            if shouldCapture {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .onDrop(
                        of: SidebarTabDragPayload.dropContentTypes,
                        delegate: SidebarExternalDropDelegate(draggedTabId: draggedTabId)
                    )
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct SidebarExternalDropDelegate: DropDelegate {
    let draggedTabId: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        let hasSidebarPayload = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        let shouldReset = SidebarOutsideDropResetPolicy.shouldResetDrag(
            draggedTabId: draggedTabId,
            hasSidebarDragPayload: hasSidebarPayload
        )
#if DEBUG
        dlog(
            "sidebar.dropOutside.validate tab=\(debugShortSidebarTabId(draggedTabId)) " +
            "hasType=\(hasSidebarPayload) allowed=\(shouldReset)"
        )
#endif
        return shouldReset
    }

    func dropEntered(info: DropInfo) {
#if DEBUG
        dlog("sidebar.dropOutside.entered tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        dlog("sidebar.dropOutside.exited tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
#if DEBUG
        dlog("sidebar.dropOutside.updated tab=\(debugShortSidebarTabId(draggedTabId)) op=move")
#endif
        // Explicit move proposal avoids AppKit showing a copy (+) cursor.
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
#if DEBUG
        dlog("sidebar.dropOutside.perform tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
        SidebarDragLifecycleNotification.postClearRequest(reason: "outside_sidebar_drop")
        return true
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

@MainActor
private final class SidebarShortcutHintModifierMonitor: ObservableObject {
    @Published private(set) var isModifierPressed = false

    private weak var hostWindow: NSWindow?
    private var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    private var hostWindowDidResignKeyObserver: NSObjectProtocol?
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var pendingShowWorkItem: DispatchWorkItem?

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else { return }
        removeHostWindowObservers()
        hostWindow = window
        guard let window else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        hostWindowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(from: NSEvent.modifierFlags, eventWindow: nil)
            }
        }

        hostWindowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func start() {
        guard flagsMonitor == nil else {
            update(from: NSEvent.modifierFlags, eventWindow: nil)
            return
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags, eventWindow: event.window)
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        removeHostWindowObservers()
        cancelPendingHintShow(resetVisible: true)
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isCurrentWindow(eventWindow: event.window) else { return }
        cancelPendingHintShow(resetVisible: true)
    }

    private func isCurrentWindow(eventWindow: NSWindow?) -> Bool {
        ShortcutHintModifierPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard ShortcutHintModifierPolicy.shouldShowHints(
            for: modifierFlags,
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        ) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        queueHintShow()
    }

    private func queueHintShow() {
        guard !isModifierPressed else { return }
        guard pendingShowWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            guard ShortcutHintModifierPolicy.shouldShowHints(
                for: NSEvent.modifierFlags,
                hostWindowNumber: self.hostWindow?.windowNumber,
                hostWindowIsKey: self.hostWindow?.isKeyWindow ?? false,
                eventWindowNumber: nil,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            ) else { return }
            self.isModifierPressed = true
        }

        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ShortcutHintModifierPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        if resetVisible {
            isModifierPressed = false
        }
    }

    private func removeHostWindowObservers() {
        if let hostWindowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidBecomeKeyObserver)
            self.hostWindowDidBecomeKeyObserver = nil
        }
        if let hostWindowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidResignKeyObserver)
            self.hostWindowDidResignKeyObserver = nil
        }
    }
}

private struct SidebarFooter: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void

    var body: some View {
#if DEBUG
        SidebarDevFooter(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
#else
        SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
#endif
    }
}

private struct SidebarFooterButtons: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
            UpdatePill(model: updateViewModel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FeedbackComposerMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FeedbackComposerMessageEditorView {
        let view = FeedbackComposerMessageEditorView()
        view.placeholder = placeholder
        view.textView.string = text
        view.textView.delegate = context.coordinator
        view.textView.setAccessibilityLabel(accessibilityLabel)
        view.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        return view
    }

    func updateNSView(_ nsView: FeedbackComposerMessageEditorView, context: Context) {
        if nsView.textView.string != text {
            nsView.textView.string = text
        }
        nsView.placeholder = placeholder
        nsView.textView.setAccessibilityLabel(accessibilityLabel)
        nsView.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedbackComposerMessageEditor

        init(parent: FeedbackComposerMessageEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class FeedbackComposerPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FeedbackComposerMessageScrollView: NSScrollView {
    weak var focusTextView: NSTextView?

    override func mouseDown(with event: NSEvent) {
        if let focusTextView {
            _ = window?.makeFirstResponder(focusTextView)
        }
        super.mouseDown(with: event)
    }
}

private final class FeedbackComposerMessageEditorView: NSView {
    private static let textInset = NSSize(width: 10, height: 10)

    let scrollView = FeedbackComposerMessageScrollView()
    let textView = NSTextView()
    private let placeholderField = FeedbackComposerPassthroughLabel(labelWithString: "")

    var placeholder: String = "" {
        didSet {
            placeholderField.stringValue = placeholder
            updatePlaceholderVisibility()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.focusTextView = textView

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        addSubview(scrollView)

        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.font = .systemFont(ofSize: 12)
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.lineBreakMode = .byWordWrapping
        placeholderField.maximumNumberOfLines = 0
        scrollView.contentView.addSubview(placeholderField)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            placeholderField.topAnchor.constraint(
                equalTo: scrollView.contentView.topAnchor,
                constant: Self.textInset.height
            ),
            placeholderField.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor,
                constant: Self.textInset.width
            ),
            placeholderField.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentView.trailingAnchor,
                constant: -Self.textInset.width
            ),
        ])

        updatePlaceholderVisibility()
    }

    override func layout() {
        super.layout()
        syncTextViewFrameToContentSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = textView.string.isEmpty == false
    }

    private func syncTextViewFrameToContentSize() {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        let targetSize = NSSize(
            width: contentSize.width,
            height: max(textView.frame.height, contentSize.height)
        )
        if textView.frame.size != targetSize {
            textView.frame = NSRect(origin: .zero, size: targetSize)
        }
    }
}

private enum SidebarHelpMenuAction {
    case importBrowserData
    case keyboardShortcuts
    case docs
    case changelog
    case github
    case githubIssues
    case discord
    case checkForUpdates
    case sendFeedback
    case welcome
}

private struct SidebarFeedbackComposerSheet: View {
    @AppStorage(FeedbackComposerSettings.storedEmailKey) private var email = ""
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var attachments: [FeedbackComposerAttachment] = []
    @State private var isSubmitting = false
    @State private var submissionErrorMessage: String?
    @State private var didSend = false

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        isValidEmail(email) &&
            !trimmedMessage.isEmpty &&
            message.count <= FeedbackComposerSettings.maxMessageLength &&
            !isSubmitting &&
            !didSend
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "sidebar.help.feedback.title", defaultValue: "Send Feedback"))
                .font(.title3.weight(.semibold))

            if didSend {
                successView
            } else {
                formView
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityIdentifier("SidebarFeedbackDialog")
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "sidebar.help.feedback.successTitle", defaultValue: "Thanks for the feedback."))
                .font(.headline)
            Text(
                String(
                    localized: "sidebar.help.feedback.successBody",
                    defaultValue: "You can also reach us at founders@manaflow.com."
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            HStack {
                Spacer()
                Button(String(localized: "sidebar.help.feedback.done", defaultValue: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                String(
                    localized: "sidebar.help.feedback.note",
                    defaultValue: "A human will read this! You can also reach us at founders@manaflow.com."
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "sidebar.help.feedback.email", defaultValue: "Your Email"))
                    .font(.system(size: 12, weight: .medium))
                TextField(
                    String(localized: "sidebar.help.feedback.emailPlaceholder", defaultValue: "you@example.com"),
                    text: $email
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "sidebar.help.feedback.email", defaultValue: "Your Email"))
                .accessibilityIdentifier("SidebarFeedbackEmailField")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "sidebar.help.feedback.message", defaultValue: "Message"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("\(message.count)/\(FeedbackComposerSettings.maxMessageLength)")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            message.count > FeedbackComposerSettings.maxMessageLength
                                ? Color.red
                                : Color.secondary
                        )
                }

                FeedbackComposerMessageEditor(
                    text: $message,
                    placeholder: String(
                        localized: "sidebar.help.feedback.messagePlaceholder",
                        defaultValue: "Share feedback, feature requests, or issues."
                    ),
                    accessibilityLabel: String(localized: "sidebar.help.feedback.message", defaultValue: "Message"),
                    accessibilityIdentifier: "SidebarFeedbackMessageEditor"
                )
                .frame(minHeight: 180)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        chooseAttachments()
                    } label: {
                        Label(
                            String(localized: "sidebar.help.feedback.attachImages", defaultValue: "Attach Images"),
                            systemImage: "paperclip"
                        )
                    }
                    .accessibilityIdentifier("SidebarFeedbackAttachButton")

                    Text(
                        String(
                            localized: "sidebar.help.feedback.attachmentsHint",
                            defaultValue: "Up to 10 images."
                        )
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                if attachments.isEmpty == false {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                                Text(attachment.fileName)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(attachment.displaySize)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Button(
                                    String(localized: "sidebar.help.feedback.removeAttachment", defaultValue: "Remove")
                                ) {
                                    removeAttachment(attachment)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }

            if let submissionErrorMessage, submissionErrorMessage.isEmpty == false {
                Text(submissionErrorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(String(localized: "sidebar.help.feedback.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await submitFeedback() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(localized: "sidebar.help.feedback.send", defaultValue: "Send"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .accessibilityIdentifier("SidebarFeedbackSendButton")
            }
        }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = String(
            localized: "sidebar.help.feedback.attachImages.title",
            defaultValue: "Attach Images"
        )
        panel.prompt = String(
            localized: "sidebar.help.feedback.attachImages.prompt",
            defaultValue: "Attach"
        )

        guard panel.runModal() == .OK else { return }

        var updatedAttachments = attachments
        var knownPaths = Set(updatedAttachments.map(\.standardizedPath))
        var firstIssue: String?

        for url in panel.urls {
            let normalizedPath = url.standardizedFileURL.path
            if knownPaths.contains(normalizedPath) {
                continue
            }
            if updatedAttachments.count >= FeedbackComposerSettings.maxAttachmentCount {
                firstIssue = String(
                    localized: "sidebar.help.feedback.tooManyImages",
                    defaultValue: "You can attach up to 10 images."
                )
                break
            }

            guard let attachment = try? FeedbackComposerAttachment(url: url) else {
                firstIssue = String(
                    localized: "sidebar.help.feedback.invalidImageSelection",
                    defaultValue: "One of the selected files could not be attached."
                )
                continue
            }
            updatedAttachments.append(attachment)
            knownPaths.insert(normalizedPath)
        }

        attachments = updatedAttachments
        submissionErrorMessage = firstIssue
    }

    private func removeAttachment(_ attachment: FeedbackComposerAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        submissionErrorMessage = nil
    }

    private func submitFeedback() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = trimmedMessage

        guard isValidEmail(trimmedEmail) else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.invalidEmail",
                defaultValue: "Enter a valid email address."
            )
            return
        }

        guard normalizedMessage.isEmpty == false else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.emptyMessage",
                defaultValue: "Enter a message before sending."
            )
            return
        }

        guard message.count <= FeedbackComposerSettings.maxMessageLength else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.messageTooLong",
                defaultValue: "Your message is too long."
            )
            return
        }

        await MainActor.run {
            email = trimmedEmail
            submissionErrorMessage = nil
            isSubmitting = true
        }

        do {
            try await FeedbackComposerClient.submit(
                email: trimmedEmail,
                message: normalizedMessage,
                attachments: attachments
            )
            await MainActor.run {
                isSubmitting = false
                didSend = true
                attachments = []
            }
        } catch {
            await MainActor.run {
                isSubmitting = false
                submissionErrorMessage = userFacingErrorMessage(for: error)
            }
        }
    }

    private func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        guard let submissionError = error as? FeedbackComposerSubmissionError else {
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again."
            )
        }

        switch submissionError {
        case .invalidEndpoint:
            return String(
                localized: "sidebar.help.feedback.endpointError",
                defaultValue: "Feedback is unavailable right now. Email founders@manaflow.com instead."
            )
        case .invalidResponse:
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again."
            )
        case .attachmentReadFailed:
            return String(
                localized: "sidebar.help.feedback.invalidImageSelection",
                defaultValue: "One of the selected files could not be attached."
            )
        case .attachmentPreparationFailed:
            return String(
                localized: "sidebar.help.feedback.totalImagesTooLarge",
                defaultValue: "These images are too large to send together. Remove a few and try again."
            )
        case .transport(let transportError):
            if transportError.code == .notConnectedToInternet || transportError.code == .networkConnectionLost {
                return String(
                    localized: "sidebar.help.feedback.connectionError",
                    defaultValue: "Couldn't send feedback. Check your connection and try again."
                )
            }
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again."
            )
        case .rejected(let statusCode):
            switch statusCode {
            case 400, 413, 415:
                return String(
                    localized: "sidebar.help.feedback.validationError",
                    defaultValue: "Check your message and attachments, then try again."
                )
            case 429:
                return String(
                    localized: "sidebar.help.feedback.rateLimited",
                    defaultValue: "Too many feedback attempts. Please try again later."
                )
            case 500...599:
                return String(
                    localized: "sidebar.help.feedback.endpointError",
                    defaultValue: "Feedback is unavailable right now. Email founders@manaflow.com instead."
                )
            default:
                return String(
                    localized: "sidebar.help.feedback.genericError",
                    defaultValue: "Couldn't send feedback. Please try again."
                )
            }
        }
    }
}

enum FeedbackComposerBridgeError: LocalizedError {
    case invalidEmail
    case emptyMessage
    case messageTooLong
    case tooManyImages
    case invalidImagePath(String)
    case submissionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "Enter a valid email address."
        case .emptyMessage:
            return "Enter a message before sending."
        case .messageTooLong:
            return "Your message is too long."
        case .tooManyImages:
            return "You can attach up to 10 images."
        case .invalidImagePath(let path):
            return "Could not attach image: \(path)"
        case .submissionFailed(let message):
            return message
        }
    }
}

enum FeedbackComposerBridge {
    static func openComposer(in window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) {
        NotificationCenter.default.post(name: .feedbackComposerRequested, object: window)
    }

    static func submit(
        email: String,
        message: String,
        imagePaths: [String]
    ) async throws -> Int {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidEmail(trimmedEmail) else {
            throw FeedbackComposerBridgeError.invalidEmail
        }
        guard normalizedMessage.isEmpty == false else {
            throw FeedbackComposerBridgeError.emptyMessage
        }
        guard message.count <= FeedbackComposerSettings.maxMessageLength else {
            throw FeedbackComposerBridgeError.messageTooLong
        }
        guard imagePaths.count <= FeedbackComposerSettings.maxAttachmentCount else {
            throw FeedbackComposerBridgeError.tooManyImages
        }

        let attachments = try imagePaths.map { rawPath in
            let resolvedURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            do {
                return try FeedbackComposerAttachment(url: resolvedURL)
            } catch {
                throw FeedbackComposerBridgeError.invalidImagePath(resolvedURL.path)
            }
        }

        do {
            try await FeedbackComposerClient.submit(
                email: trimmedEmail,
                message: normalizedMessage,
                attachments: attachments
            )
        } catch {
            throw FeedbackComposerBridgeError.submissionFailed(userFacingMessage(for: error))
        }

        UserDefaults.standard.set(trimmedEmail, forKey: FeedbackComposerSettings.storedEmailKey)
        return attachments.count
    }

    private static func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    private static func userFacingMessage(for error: Error) -> String {
        guard let submissionError = error as? FeedbackComposerSubmissionError else {
            return "Couldn't send feedback. Please try again."
        }

        switch submissionError {
        case .invalidEndpoint:
            return "Feedback is unavailable right now. Email founders@manaflow.com instead."
        case .invalidResponse:
            return "Couldn't send feedback. Please try again."
        case .attachmentReadFailed:
            return "One of the selected files could not be attached."
        case .attachmentPreparationFailed:
            return "These images are too large to send together. Remove a few and try again."
        case .transport(let transportError):
            if transportError.code == .notConnectedToInternet || transportError.code == .networkConnectionLost {
                return "Couldn't send feedback. Check your connection and try again."
            }
            return "Couldn't send feedback. Please try again."
        case .rejected(let statusCode):
            switch statusCode {
            case 400, 413, 415:
                return "Check your message and attachments, then try again."
            case 429:
                return "Too many feedback attempts. Please try again later."
            case 500...599:
                return "Feedback is unavailable right now. Email founders@manaflow.com instead."
            default:
                return "Couldn't send feedback. Please try again."
            }
        }
    }
}

private struct SidebarHelpMenuButton: View {
    private let docsURL = URL(string: "https://cmux.com/docs")
    private let changelogURL = URL(string: "https://cmux.com/docs/changelog")
    private let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private let githubIssuesURL = URL(string: "https://github.com/manaflow-ai/cmux/issues")
    private let discordURL = URL(string: "https://discord.gg/xsgFEVrWCZ")
    private let helpTitle = String(localized: "sidebar.help.button", defaultValue: "Help")
    private let buttonSize: CGFloat = 22
    private let iconSize: CGFloat = 11
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    let onSendFeedback: () -> Void

    @State private var isPopoverPresented = false

    private var sendFeedbackShortcutHint: String {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .sendFeedback).displayString
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            helpPopover
        })
        .accessibilityElement(children: .ignore)
        .safeHelp(helpTitle)
        .accessibilityLabel(helpTitle)
        .accessibilityIdentifier("SidebarHelpMenuButton")
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            helpOptionButton(
                title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
                action: .welcome,
                accessibilityIdentifier: "SidebarHelpMenuOptionWelcome",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
                action: .sendFeedback,
                accessibilityIdentifier: "SidebarHelpMenuOptionSendFeedback",
                isExternalLink: false,
                shortcutHint: sendFeedbackShortcutHint,
                trailingSystemImage: "bubble.left.and.text.bubble.right"
            )
            helpOptionButton(
                title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
                action: .keyboardShortcuts,
                accessibilityIdentifier: "SidebarHelpMenuOptionKeyboardShortcuts",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
                action: .importBrowserData,
                accessibilityIdentifier: "SidebarHelpMenuOptionImportBrowserData",
                isExternalLink: false
            )
            if docsURL != nil {
                helpOptionButton(
                    title: String(localized: "about.docs", defaultValue: "Docs"),
                    action: .docs,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDocs",
                    isExternalLink: true
                )
            }
            if changelogURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"),
                    action: .changelog,
                    accessibilityIdentifier: "SidebarHelpMenuOptionChangelog",
                    isExternalLink: true
                )
            }
            if githubURL != nil {
                helpOptionButton(
                    title: String(localized: "about.github", defaultValue: "GitHub"),
                    action: .github,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHub",
                    isExternalLink: true
                )
            }
            if githubIssuesURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"),
                    action: .githubIssues,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHubIssues",
                    isExternalLink: true
                )
            }
            if discordURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.discord", defaultValue: "Discord"),
                    action: .discord,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDiscord",
                    isExternalLink: true
                )
            }
            helpOptionButton(
                title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
                action: .checkForUpdates,
                accessibilityIdentifier: "SidebarHelpMenuOptionCheckForUpdates",
                isExternalLink: false
            )
        }
        .padding(8)
        .frame(minWidth: 200)
    }

    private func helpOptionButton(
        title: String,
        action: SidebarHelpMenuAction,
        accessibilityIdentifier: String,
        isExternalLink: Bool,
        shortcutHint: String? = nil,
        trailingSystemImage: String? = nil
    ) -> some View {
        Button {
            isPopoverPresented = false
            perform(action)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                if let shortcutHint {
                    helpOptionShortcutHint(text: shortcutHint)
                }
                if let trailingSystemImage {
                    helpOptionTrailingIcon(systemName: trailingSystemImage)
                }
                if isExternalLink {
                    helpOptionTrailingIcon(systemName: "arrow.up.right", size: 8)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func helpOptionShortcutHint(text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: 10, weight: .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func helpOptionTrailingIcon(systemName: String, size: CGFloat = 13) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func perform(_ action: SidebarHelpMenuAction) {
        switch action {
        case .importBrowserData:
            isPopoverPresented = false
            DispatchQueue.main.async {
                BrowserDataImportCoordinator.shared.presentImportDialog()
            }
        case .keyboardShortcuts:
            isPopoverPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Task { @MainActor in
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.openPreferencesWindow(
                            debugSource: "sidebarHelpMenu.keyboardShortcuts",
                            navigationTarget: .keyboardShortcuts
                        )
                    } else {
                        AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
                    }
                }
            }
        case .docs:
            guard let docsURL else { return }
            NSWorkspace.shared.open(docsURL)
        case .changelog:
            guard let changelogURL else { return }
            NSWorkspace.shared.open(changelogURL)
        case .github:
            guard let githubURL else { return }
            NSWorkspace.shared.open(githubURL)
        case .githubIssues:
            guard let githubIssuesURL else { return }
            NSWorkspace.shared.open(githubIssuesURL)
        case .discord:
            guard let discordURL else { return }
            NSWorkspace.shared.open(discordURL)
        case .checkForUpdates:
            Task { @MainActor in
                AppDelegate.shared?.checkForUpdates(nil)
            }
        case .sendFeedback:
            isPopoverPresented = false
            onSendFeedback()
        case .welcome:
            isPopoverPresented = false
            Task { @MainActor in
                if let appDelegate = AppDelegate.shared {
                    appDelegate.openWelcomeWorkspace()
                }
            }
        }
    }

}

private struct ArrowlessPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let detachedGap: CGFloat
    @ViewBuilder let content: () -> PopoverContent

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.updateRootView(AnyView(content()))

        if isPresented {
            context.coordinator.present(
                preferredEdge: preferredEdge,
                detachedGap: detachedGap
            )
        } else {
            context.coordinator.dismiss()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool

        weak var anchorView: NSView?
        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func updateRootView(_ rootView: AnyView) {
            hostingController.rootView = AnyView(rootView.fixedSize())
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
        }

        func present(preferredEdge: NSRectEdge, detachedGap: CGFloat) {
            guard let anchorView else {
                isPresented = false
                dismiss()
                return
            }

            let popover = popover ?? makePopover()
            if popover.isShown {
                return
            }

            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            let fittingSize = hostingController.view.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                popover.contentSize = NSSize(
                    width: ceil(fittingSize.width),
                    height: ceil(fittingSize.height)
                )
            }

            popover.show(
                relativeTo: positioningRect(
                    for: anchorView.bounds,
                    preferredEdge: preferredEdge,
                    detachedGap: detachedGap
                ),
                of: anchorView,
                preferredEdge: preferredEdge
            )
        }

        func dismiss() {
            popover?.performClose(nil)
            popover = nil
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = true
            popover.setValue(true, forKeyPath: "shouldHideAnchor")
            popover.contentViewController = hostingController
            popover.delegate = self
            self.popover = popover
            return popover
        }

        private func positioningRect(
            for bounds: CGRect,
            preferredEdge: NSRectEdge,
            detachedGap: CGFloat
        ) -> CGRect {
            let hiddenArrowInset: CGFloat = 13
            let compensation = max(hiddenArrowInset - detachedGap, 0)

            switch preferredEdge {
            case .maxY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.maxY - compensation,
                    width: bounds.width,
                    height: compensation
                )
            case .minY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: compensation
                )
            case .maxX:
                return NSRect(
                    x: bounds.maxX - compensation,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            case .minX:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            @unknown default:
                return bounds
            }
        }
    }
}

private struct SidebarFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterIconButtonStyleBody(configuration: configuration)
    }
}

private struct SidebarFooterIconButtonStyleBody: View {
    let configuration: SidebarFooterIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#if DEBUG
private struct SidebarDevFooter: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
            if showSidebarDevBuildBanner {
                Text(String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }
}
#endif

private struct SidebarTopScrim: View {
    let height: CGFloat

    var body: some View {
        SidebarTopBlurEffect()
            .frame(height: height)
            .mask(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.95),
                        Color.black.opacity(0.75),
                        Color.black.opacity(0.35),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

private struct SidebarTopBlurEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .underWindowBackground
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct SidebarScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> SidebarScrollViewResolverView {
        let view = SidebarScrollViewResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: SidebarScrollViewResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveScrollView()
    }
}

private final class SidebarScrollViewResolverView: NSView {
    var onResolve: ((NSScrollView?) -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollView()
    }

    func resolveScrollView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onResolve?(self.enclosingScrollView)
        }
    }
}

private struct SidebarEmptyArea: View {
    @EnvironmentObject var tabManager: TabManager
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2) {
                tabManager.addWorkspace(placementOverride: .end)
                if let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            }
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: SidebarTabDropDelegate(
                targetTabId: nil,
                tabManager: tabManager,
                draggedTabId: $draggedTabId,
                selectedTabIds: $selectedTabIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                targetRowHeight: nil,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastTabId = tabManager.tabs.last?.id else { return false }
        return indicator.tabId == lastTabId
    }
}

enum SidebarPathFormatter {
    static let homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path

    static func shortenedPath(
        _ path: String,
        homeDirectoryPath: String = Self.homeDirectoryPath
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == homeDirectoryPath {
            return "~"
        }
        if trimmed.hasPrefix(homeDirectoryPath + "/") {
            return "~" + trimmed.dropFirst(homeDirectoryPath.count)
        }
        return trimmed
    }
}

enum SidebarWorkspaceShortcutHintMetrics {
    private static let measurementFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let minimumSlotWidth: CGFloat = 28
    private static let horizontalPadding: CGFloat = 12
    private static let lock = NSLock()
    private static var cachedHintWidths: [String: CGFloat] = [:]
    #if DEBUG
    private static var measurementCount = 0
    #endif

    static func slotWidth(label: String?, debugXOffset: Double) -> CGFloat {
        guard let label else { return minimumSlotWidth }
        let positiveDebugInset = max(0, CGFloat(ShortcutHintDebugSettings.clamped(debugXOffset))) + 2
        return max(minimumSlotWidth, hintWidth(for: label) + positiveDebugInset)
    }

    static func hintWidth(for label: String) -> CGFloat {
        lock.lock()
        if let cached = cachedHintWidths[label] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let textWidth = (label as NSString).size(withAttributes: [.font: measurementFont]).width
        let measuredWidth = ceil(textWidth) + horizontalPadding

        lock.lock()
        cachedHintWidths[label] = measuredWidth
        #if DEBUG
        measurementCount += 1
        #endif
        lock.unlock()
        return measuredWidth
    }

    #if DEBUG
    static func resetCacheForTesting() {
        lock.lock()
        cachedHintWidths.removeAll()
        measurementCount = 0
        lock.unlock()
    }

    static func measurementCountForTesting() -> Int {
        lock.lock()
        let count = measurementCount
        lock.unlock()
        return count
    }
    #endif
}

enum SidebarTrailingAccessoryWidthPolicy {
    static let closeButtonWidth: CGFloat = 16

    static func width(
        canCloseWorkspace: Bool
    ) -> CGFloat {
        return canCloseWorkspace ? closeButtonWidth : 0
    }
}

// PERF: TabItemView is Equatable so SwiftUI skips body re-evaluation when
// the parent rebuilds with unchanged values. Without this, every TabManager
// or NotificationStore publish causes ALL tab items to re-evaluate (~18% of
// main thread during typing). If you add new properties, update == below.
// Reactive workspace state inside the row must not rely on parent diffs alone:
// `.equatable()` can otherwise leave sidebar badges/details stale until an
// unrelated parent change sneaks through. Keep the workspace reference plain
// and bridge only sidebar-visible workspace changes into local state.
// Do NOT add @EnvironmentObject or new @Binding without updating ==.
// Do NOT remove .equatable() from the ForEach call site in VerticalTabsSidebar.
struct SidebarWorkspaceSnapshotBuilder {
    struct VerticalBranchDirectoryLine: Equatable {
        let branch: String?
        let directory: String?
    }

    struct PullRequestDisplay: Identifiable, Equatable {
        let id: String
        let number: Int
        let label: String
        let url: URL
        let status: SidebarPullRequestStatus
        let isStale: Bool
    }

    struct Snapshot: Equatable {
        let title: String
        let customDescription: String?
        let isPinned: Bool
        let customColorHex: String?
        let remoteWorkspaceSidebarText: String?
        let remoteConnectionStatusText: String
        let remoteStateHelpText: String
        let copyableSidebarSSHError: String?
        let metadataEntries: [SidebarStatusEntry]
        let metadataBlocks: [SidebarMetadataBlock]
        let latestLog: SidebarLogEntry?
        let progress: SidebarProgressState?
        let compactGitBranchSummaryText: String?
        let compactBranchDirectoryRow: String?
        let branchDirectoryLines: [VerticalBranchDirectoryLine]
        let branchLinesContainBranch: Bool
        let pullRequestRows: [PullRequestDisplay]
        let listeningPorts: [Int]
    }
}

private final class SidebarTabItemContextMenuState: ObservableObject {
    var isVisible = false
    var hasDeferredWorkspaceObservationInvalidation = false
    var pendingWorkspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot?
}

private struct TabItemView: View, Equatable {
    private static let workspaceObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)

    // Closures, Bindings, and object references are excluded from ==
    // because they're recreated every parent eval but don't affect rendering.
    nonisolated static func == (lhs: TabItemView, rhs: TabItemView) -> Bool {
        lhs.tab === rhs.tab &&
        lhs.index == rhs.index &&
        lhs.isActive == rhs.isActive &&
        lhs.workspaceShortcutDigit == rhs.workspaceShortcutDigit &&
        lhs.workspaceShortcutModifierSymbol == rhs.workspaceShortcutModifierSymbol &&
        lhs.canCloseWorkspace == rhs.canCloseWorkspace &&
        lhs.accessibilityWorkspaceCount == rhs.accessibilityWorkspaceCount &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.latestNotificationText == rhs.latestNotificationText &&
        lhs.rowSpacing == rhs.rowSpacing &&
        lhs.showsModifierShortcutHints == rhs.showsModifierShortcutHints &&
        lhs.contextMenuWorkspaceIds == rhs.contextMenuWorkspaceIds &&
        lhs.remoteContextMenuWorkspaceIds == rhs.remoteContextMenuWorkspaceIds &&
        lhs.allRemoteContextMenuTargetsConnecting == rhs.allRemoteContextMenuTargetsConnecting &&
        lhs.allRemoteContextMenuTargetsDisconnected == rhs.allRemoteContextMenuTargetsDisconnected &&
        lhs.allContextMenuWorkspacesHideTerminalScrollBar == rhs.allContextMenuWorkspacesHideTerminalScrollBar &&
        lhs.settings == rhs.settings
    }

    // Use plain references instead of @EnvironmentObject to avoid subscribing
    // to ALL changes on these objects. Body reads use precomputed parameters;
    // action handlers use the plain references without triggering re-evaluation.
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    let tab: Tab
    let index: Int
    let isActive: Bool
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let accessibilityWorkspaceCount: Int
    let unreadCount: Int
    let latestNotificationText: String?
    let rowSpacing: CGFloat
    let setSelectionToTabs: () -> Void
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let showsModifierShortcutHints: Bool
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let allContextMenuWorkspacesHideTerminalScrollBar: Bool
    let settings: SidebarTabItemSettingsSnapshot
    let livePresentation: SidebarTabItemPresentationSnapshot
    @Binding var frozenPresentation: SidebarTabItemPresentationSnapshot?
    @State private var workspaceSnapshotStorage: SidebarWorkspaceSnapshotBuilder.Snapshot?
    @StateObject private var contextMenuState = SidebarTabItemContextMenuState()
    @State private var isHovering = false
    @State private var rowHeight: CGFloat = 1

    var isMultiSelected: Bool {
        selectedTabIds.contains(tab.id)
    }

    private var isBeingDragged: Bool {
        draggedTabId == tab.id
    }

    private var sidebarShortcutHintXOffset: Double {
        settings.sidebarShortcutHintXOffset
    }

    private var sidebarShortcutHintYOffset: Double {
        settings.sidebarShortcutHintYOffset
    }

    private var alwaysShowShortcutHints: Bool {
        settings.alwaysShowShortcutHints
    }

    private var sidebarShowGitBranch: Bool {
        settings.showsGitBranch
    }

    private var sidebarBranchVerticalLayout: Bool {
        settings.usesVerticalBranchLayout
    }

    private var sidebarShowGitBranchIcon: Bool {
        settings.showsGitBranchIcon
    }

    private var sidebarShowSSH: Bool {
        settings.showsSSH
    }

    private var workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot {
        workspaceSnapshotStorage ?? makeWorkspaceSnapshot()
    }

    private var activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        settings.activeTabIndicatorStyle
    }

    private var sidebarSelectionColorHex: String? {
        settings.selectionColorHex
    }

    private var sidebarNotificationBadgeColorHex: String? {
        settings.notificationBadgeColorHex
    }

    private var openSidebarPullRequestLinksInCmuxBrowser: Bool {
        settings.openPullRequestLinksInCmuxBrowser
    }

    private var openSidebarPortLinksInCmuxBrowser: Bool {
        settings.openPortLinksInCmuxBrowser
    }

    private var titleFontWeight: Font.Weight {
        .semibold
    }

    private var showsLeadingRail: Bool {
        explicitRailColor != nil
    }

    private var activeBorderLineWidth: CGFloat {
        switch activeTabIndicatorStyle {
        case .leftRail:
            return 0
        case .solidFill:
            return isActive ? 1.5 : 0
        }
    }

    private var activeBorderColor: Color {
        guard isActive else { return .clear }
        switch activeTabIndicatorStyle {
        case .leftRail:
            return .clear
        case .solidFill:
            return Color.primary.opacity(0.5)
        }
    }

    private var usesInvertedActiveForeground: Bool {
        isActive
    }

    private var activePrimaryTextColor: Color {
        usesInvertedActiveForeground
            ? Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 1.0))
            : .primary
    }

    private func activeSecondaryColor(_ opacity: Double = 0.75) -> Color {
        usesInvertedActiveForeground
            ? Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat(opacity)))
            : .secondary
    }

    private var activeUnreadBadgeFillColor: Color {
        if let hex = sidebarNotificationBadgeColorHex, let nsColor = NSColor(hex: hex) {
            return Color(nsColor: nsColor)
        }
        return usesInvertedActiveForeground ? Color.white.opacity(0.25) : cmuxAccentColor()
    }

    private var activeProgressTrackColor: Color {
        usesInvertedActiveForeground ? Color.white.opacity(0.15) : Color.secondary.opacity(0.2)
    }

    private var activeProgressFillColor: Color {
        usesInvertedActiveForeground ? Color.white.opacity(0.8) : cmuxAccentColor()
    }

    private var shortcutHintEmphasis: Double {
        usesInvertedActiveForeground ? 1.0 : 0.9
    }

    private var showCloseButton: Bool {
        isHovering && canCloseWorkspace && !(showsModifierShortcutHints || alwaysShowShortcutHints)
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "\(workspaceShortcutModifierSymbol)\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsModifierShortcutHints || alwaysShowShortcutHints) && workspaceShortcutLabel != nil
    }

    private var trailingAccessoryWidth: CGFloat {
        SidebarTrailingAccessoryWidthPolicy.width(
            canCloseWorkspace: canCloseWorkspace
        )
    }

    private var remoteWorkspaceSidebarText: String? {
        guard tab.hasActiveRemoteTerminalSessions else { return nil }
        let trimmedTarget = tab.remoteDisplayTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTarget, !trimmedTarget.isEmpty {
            return trimmedTarget
        }
        return String(localized: "sidebar.remote.subtitleFallback", defaultValue: "SSH workspace")
    }

    private var copyableSidebarSSHError: String? {
        let fallbackTarget = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let trimmedDetail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab.remoteConnectionState == .error, let trimmedDetail, !trimmedDetail.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: trimmedDetail
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        if let statusValue = tab.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: statusValue
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        return nil
    }

    private var remoteConnectionStatusText: String {
        switch tab.remoteConnectionState {
        case .connected:
            return String(localized: "remote.status.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "remote.status.connecting", defaultValue: "Connecting")
        case .error:
            return String(localized: "remote.status.error", defaultValue: "Error")
        case .disconnected:
            return String(localized: "remote.status.disconnected", defaultValue: "Disconnected")
        }
    }

    @ViewBuilder
    private var remoteWorkspaceSection: some View {
        let workspaceSnapshot = self.workspaceSnapshot
        if sidebarShowSSH, let remoteWorkspaceSidebarText = workspaceSnapshot.remoteWorkspaceSidebarText {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(remoteWorkspaceSidebarText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    Text(workspaceSnapshot.remoteConnectionStatusText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(activeSecondaryColor(0.58))
                        .lineLimit(1)
                }
            }
            .padding(.top, latestNotificationText == nil ? 1 : 2)
            .safeHelp(workspaceSnapshot.remoteStateHelpText)
        }
    }

    private func copyTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility {
        settings.visibleAuxiliaryDetails
    }

    var body: some View {
        let workspaceSnapshot = self.workspaceSnapshot
        let closeWorkspaceTooltip = String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close Workspace")
        let protectedWorkspaceTooltip = String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip",
            defaultValue: "Pinned workspace. Closing requires confirmation."
        )
        let closeButtonTooltip = workspaceSnapshot.isPinned
            ? protectedWorkspaceTooltip
            : KeyboardShortcutSettings.Action.closeWorkspace.tooltip(closeWorkspaceTooltip)
        let accessibilityHintText = String(localized: "sidebar.workspace.accessibilityHint", defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.")
        let moveUpActionText = String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up")
        let moveDownActionText = String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down")
        let latestNotificationSubtitle = latestNotificationText
        let effectiveSubtitle = latestNotificationSubtitle
        let detailVisibility = visibleAuxiliaryDetails

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if unreadCount > 0 {
                    ZStack {
                        Circle()
                            .fill(activeUnreadBadgeFillColor)
                        Text("\(unreadCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 16, height: 16)
                }

                if workspaceSnapshot.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .safeHelp(protectedWorkspaceTooltip)
                }

                Text(workspaceSnapshot.title)
                    .font(.system(size: 12.5, weight: titleFontWeight))
                    .foregroundColor(activePrimaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                ZStack(alignment: .trailing) {
                    Button(action: {
                        #if DEBUG
                        dlog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=button")
                        #endif
                        tabManager.closeWorkspaceWithConfirmation(tab)
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(activeSecondaryColor(0.7))
                    }
                    .buttonStyle(.plain)
                    .safeHelp(closeButtonTooltip)
                    .frame(width: SidebarTrailingAccessoryWidthPolicy.closeButtonWidth, height: 16, alignment: .center)
                    .opacity(showCloseButton && !showsWorkspaceShortcutHint ? 1 : 0)
                    .allowsHitTesting(showCloseButton && !showsWorkspaceShortcutHint)

                    if showsWorkspaceShortcutHint, let workspaceShortcutLabel {
                        ShortcutHintPill(text: workspaceShortcutLabel, fontSize: 10, emphasis: shortcutHintEmphasis)
                            .offset(
                                x: ShortcutHintDebugSettings.clamped(sidebarShortcutHintXOffset),
                                y: ShortcutHintDebugSettings.clamped(sidebarShortcutHintYOffset)
                            )
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: showsModifierShortcutHints || alwaysShowShortcutHints)
                .frame(width: trailingAccessoryWidth, height: 16, alignment: .trailing)
            }

            if let description = workspaceSnapshot.customDescription {
                SidebarWorkspaceDescriptionText(
                    markdown: description,
                    isActive: usesInvertedActiveForeground
                )
                .id(description)
            }

            if let subtitle = effectiveSubtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(activeSecondaryColor(0.8))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }

            remoteWorkspaceSection

            if detailVisibility.showsMetadata {
                let metadataEntries = workspaceSnapshot.metadataEntries
                let metadataBlocks = workspaceSnapshot.metadataBlocks
                if !metadataEntries.isEmpty {
                    SidebarMetadataRows(
                        entries: metadataEntries,
                        isActive: usesInvertedActiveForeground,
                        onFocus: { updateSelection() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !metadataBlocks.isEmpty {
                    SidebarMetadataMarkdownBlocks(
                        blocks: metadataBlocks,
                        isActive: usesInvertedActiveForeground,
                        onFocus: { updateSelection() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Latest log entry
            if detailVisibility.showsLog, let latestLog = workspaceSnapshot.latestLog {
                HStack(spacing: 4) {
                    Image(systemName: logLevelIcon(latestLog.level))
                        .font(.system(size: 8))
                        .foregroundColor(logLevelColor(latestLog.level, isActive: usesInvertedActiveForeground))
                    Text(latestLog.message)
                        .font(.system(size: 10))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Progress bar
            if detailVisibility.showsProgress, let progress = workspaceSnapshot.progress {
                VStack(alignment: .leading, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(activeProgressTrackColor)
                            Capsule()
                                .fill(activeProgressFillColor)
                                .frame(width: max(0, geo.size.width * CGFloat(progress.value)))
                        }
                    }
                    .frame(height: 3)

                    if let label = progress.label {
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundColor(activeSecondaryColor(0.6))
                            .lineLimit(1)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Branch + directory row
            if detailVisibility.showsBranchDirectory {
                if sidebarBranchVerticalLayout {
                    if !workspaceSnapshot.branchDirectoryLines.isEmpty {
                        HStack(alignment: .top, spacing: 3) {
                            if sidebarShowGitBranchIcon, workspaceSnapshot.branchLinesContainBranch {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 9))
                                    .foregroundColor(activeSecondaryColor(0.6))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(workspaceSnapshot.branchDirectoryLines.enumerated()), id: \.offset) { _, line in
                                    HStack(spacing: 3) {
                                        if let branch = line.branch {
                                            Text(branch)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(activeSecondaryColor(0.75))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        if line.branch != nil, line.directory != nil {
                                            Image(systemName: "circle.fill")
                                                .font(.system(size: 3))
                                                .foregroundColor(activeSecondaryColor(0.6))
                                                .padding(.horizontal, 1)
                                        }
                                        if let directory = line.directory {
                                            Text(directory)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(activeSecondaryColor(0.75))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if let dirRow = workspaceSnapshot.compactBranchDirectoryRow {
                    HStack(spacing: 3) {
                        if sidebarShowGitBranchIcon, workspaceSnapshot.compactGitBranchSummaryText != nil {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                                .foregroundColor(activeSecondaryColor(0.6))
                        }
                        Text(dirRow)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(activeSecondaryColor(0.75))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            // Pull request rows
            if detailVisibility.showsPullRequests, !workspaceSnapshot.pullRequestRows.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(workspaceSnapshot.pullRequestRows) { pullRequest in
                        Button(action: {
                            openPullRequestLink(pullRequest.url)
                        }) {
                            HStack(spacing: 4) {
                                PullRequestStatusIcon(
                                    status: pullRequest.status,
                                    color: pullRequestForegroundColor
                                )
                                Text("\(pullRequest.label) #\(pullRequest.number)")
                                    .underline()
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(pullRequestStatusLabel(pullRequest.status))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(pullRequestForegroundColor)
                            .opacity(pullRequest.isStale ? 0.5 : 1)
                        }
                        .buttonStyle(.plain)
                        .safeHelp(String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open \(pullRequest.label) #\(pullRequest.number)"))
                    }
                }
            }

            // Ports row
            if detailVisibility.showsPorts, !workspaceSnapshot.listeningPorts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(workspaceSnapshot.listeningPorts, id: \.self) { port in
                        Button(action: {
                            openPortLink(port)
                        }) {
                            Text(String(localized: "sidebar.port.label", defaultValue: ":\(port)"))
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .safeHelp(String(localized: "sidebar.port.openTooltip", defaultValue: "Open localhost:\(port)"))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(activeSecondaryColor(0.75))
                .lineLimit(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: workspaceSnapshot.latestLog)
        .animation(.easeInOut(duration: 0.2), value: workspaceSnapshot.progress != nil)
        .animation(.easeInOut(duration: 0.2), value: workspaceSnapshot.metadataBlocks.count)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(activeBorderColor, lineWidth: activeBorderLineWidth)
                }
                .overlay(alignment: .leading) {
                    if showsLeadingRail {
                        Capsule(style: .continuous)
                            .fill(railColor)
                            .frame(width: 3)
                            .padding(.leading, 4)
                            .padding(.vertical, 5)
                            .offset(x: -1)
                    }
                }
        )
        .padding(.horizontal, 6)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        rowHeight = max(proxy.size.height, 1)
                    }
                    .onChange(of: proxy.size.height) { newHeight in
                        rowHeight = max(newHeight, 1)
                    }
            }
        }
        .contentShape(Rectangle())
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay {
            MiddleClickCapture {
                #if DEBUG
                dlog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=middleClick")
                #endif
                tabManager.closeWorkspaceWithConfirmation(tab)
            }
        }
        .overlay(alignment: .top) {
            if showsCenteredTopDropIndicator {
                Rectangle()
                    .fill(cmuxAccentColor())
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .offset(y: index == 0 ? 0 : -(rowSpacing / 2))
            }
        }
        .onAppear {
            refreshWorkspaceSnapshot(force: true)
        }
        .onReceive(
            tab.sidebarImmediateObservationPublisher
                .receive(on: RunLoop.main)
        ) { _ in
#if DEBUG
            let description = tab.customDescription ?? ""
            dlog(
                "sidebar.row.invalidate workspace=\(tab.id.uuidString.prefix(8)) " +
                "source=immediate " +
                "title=\"\(debugCommandPaletteTextPreview(tab.title))\" " +
                "descLen=\((description as NSString).length) " +
                "desc=\"\(debugCommandPaletteTextPreview(description))\""
            )
#endif
            refreshWorkspaceSnapshot()
        }
        .onReceive(
            tab.sidebarObservationPublisher
                .receive(on: RunLoop.main)
                // Prompt-time sidebar telemetry can arrive as a short burst
                // (pwd, branch, PR, shell state). Coalesce that burst so the
                // row redraws once with the settled state instead of blinking.
                .debounce(for: Self.workspaceObservationCoalesceInterval, scheduler: RunLoop.main)
        ) { _ in
#if DEBUG
            let description = tab.customDescription ?? ""
            dlog(
                "sidebar.row.invalidate workspace=\(tab.id.uuidString.prefix(8)) " +
                "source=debounced " +
                "title=\"\(debugCommandPaletteTextPreview(tab.title))\" " +
                "descLen=\((description as NSString).length) " +
                "desc=\"\(debugCommandPaletteTextPreview(description))\""
            )
#endif
            refreshWorkspaceSnapshot()
        }
        .onChange(of: settings) { _ in
            refreshWorkspaceSnapshot(force: true)
        }
        .onDrag {
            #if DEBUG
            dlog("sidebar.onDrag tab=\(tab.id.uuidString.prefix(5))")
            #endif
            draggedTabId = tab.id
            dropIndicator = nil
            return SidebarTabDragPayload.provider(for: tab.id)
        }
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: SidebarTabDropDelegate(
            targetTabId: tab.id,
            tabManager: tabManager,
            draggedTabId: $draggedTabId,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: rowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: $dropIndicator
        ))
        .onDrop(of: BonsplitTabDragPayload.dropContentTypes, delegate: SidebarBonsplitTabDropDelegate(
            targetWorkspaceId: tab.id,
            tabManager: tabManager,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        ))
        .onTapGesture {
            updateSelection()
        }
        .onHover { hovering in
            guard !contextMenuState.isVisible else { return }
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityHint(Text(accessibilityHintText))
        .accessibilityAction(named: Text(moveUpActionText)) {
            moveBy(-1)
        }
        .accessibilityAction(named: Text(moveDownActionText)) {
            moveBy(1)
        }
        .contextMenu {
            workspaceContextMenu
                .onAppear {
                    contextMenuState.isVisible = true
                    contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
                    contextMenuState.pendingWorkspaceSnapshot = nil
                    frozenPresentation = livePresentation
                }
                .onDisappear {
                    contextMenuState.isVisible = false
                    frozenPresentation = nil
                    if isHovering {
                        isHovering = false
                    }
                    flushDeferredWorkspaceObservationInvalidation()
                }
        }
    }

    private func refreshWorkspaceSnapshot(force: Bool = false) {
        let nextSnapshot = makeWorkspaceSnapshot()

        if contextMenuState.isVisible {
            let deferredBaseline = contextMenuState.pendingWorkspaceSnapshot ?? workspaceSnapshotStorage
            // Color changes are driven by explicit clicks in the Workspace Color
            // submenu, and SwiftUI's context-menu content does not reliably fire
            // `.onDisappear` after a button tap (issue #3037). Apply color
            // changes immediately so the row reflects the user's selection
            // instead of waiting on a flush that may never happen.
            if deferredBaseline?.customColorHex != nextSnapshot.customColorHex {
                workspaceSnapshotStorage = nextSnapshot
                contextMenuState.pendingWorkspaceSnapshot = nil
                contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
                return
            }
            if force || deferredBaseline != nextSnapshot {
                contextMenuState.hasDeferredWorkspaceObservationInvalidation = true
                contextMenuState.pendingWorkspaceSnapshot = nextSnapshot
            }
            return
        }

        if force || workspaceSnapshotStorage != nextSnapshot {
            workspaceSnapshotStorage = nextSnapshot
        }
    }

    private func flushDeferredWorkspaceObservationInvalidation() {
        guard contextMenuState.hasDeferredWorkspaceObservationInvalidation else { return }
        contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
        if let pendingSnapshot = contextMenuState.pendingWorkspaceSnapshot {
            workspaceSnapshotStorage = pendingSnapshot
        }
        contextMenuState.pendingWorkspaceSnapshot = nil
    }

    private func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    private func remoteContextMenuWorkspaces() -> [Workspace] {
        guard !remoteContextMenuWorkspaceIds.isEmpty else { return [] }
        return remoteContextMenuWorkspaceIds.compactMap { workspaceId in
            tabManager.tabs.first(where: { $0.id == workspaceId })
        }
    }

    @ViewBuilder
    private var workspaceContextMenu: some View {
        let targetIds = contextMenuWorkspaceIds
        let isMulti = targetIds.count > 1
        let tabColorPalette = WorkspaceTabColorSettings.palette()
        let shouldPin = !tab.isPinned
        let reconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
            isMulti: isMulti)
        let disconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
            isMulti: isMulti)
        let pinLabel = shouldPin
            ? contextMenuLabel(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : contextMenuLabel(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        let closeLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        let markReadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            isMulti: isMulti)
        let markUnreadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            isMulti: isMulti)
        let clearLatestNotificationLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"),
            isMulti: isMulti)
        let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let editWorkspaceDescriptionShortcut = KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
        let closeWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        Button(pinLabel) {
            for id in targetIds {
                if let tab = tabManager.tabs.first(where: { $0.id == id }) {
                    tabManager.setPinned(tab, pinned: shouldPin)
                }
            }
            syncSelectionAfterMutation()
        }

        if let key = renameWorkspaceShortcut.keyEquivalent {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
            .keyboardShortcut(key, modifiers: renameWorkspaceShortcut.eventModifiers)
        } else {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
        }

        if tab.hasCustomTitle {
            Button(String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")) {
                tabManager.clearCustomTitle(tabId: tab.id)
            }
        }

        if !isMulti {
            if let key = editWorkspaceDescriptionShortcut.keyEquivalent {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
                .keyboardShortcut(key, modifiers: editWorkspaceDescriptionShortcut.eventModifiers)
            } else {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
            }

            if tab.hasCustomDescription {
                Button(String(localized: "contextMenu.clearWorkspaceDescription", defaultValue: "Clear Workspace Description")) {
                    tabManager.clearCustomDescription(tabId: tab.id)
                }
            }
        }

        if !remoteContextMenuWorkspaceIds.isEmpty {
            Divider()

            Button(reconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.reconnectRemoteConnection()
                }
            }
            .disabled(allRemoteContextMenuTargetsConnecting)

            Button(disconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.disconnectRemoteConnection(clearConfiguration: false)
                }
            }
            .disabled(allRemoteContextMenuTargetsDisconnected)
        }

        Menu(String(localized: "contextMenu.workspaceSettings", defaultValue: "Workspace Settings")) {
            Button {
                toggleWorkspaceTerminalScrollBarHidden(targetIds: targetIds)
            } label: {
                Label {
                    Text(String(localized: "contextMenu.workspaceSettings.hideTerminalScrollBar", defaultValue: "Hide Terminal Scroll Bar"))
                } icon: {
                    if allContextMenuWorkspacesHideTerminalScrollBar {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }

        Menu(String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color")) {
            if tab.customColor != nil {
                Button {
                    applyTabColor(nil, targetIds: targetIds)
                } label: {
                    Label(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"), systemImage: "xmark.circle")
                }
            }

            Button {
                promptCustomColor(targetIds: targetIds)
            } label: {
                Label(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"), systemImage: "paintpalette")
            }

            if !tabColorPalette.isEmpty {
                Divider()
            }

            ForEach(tabColorPalette, id: \.id) { entry in
                Button {
                    applyTabColor(entry.hex, targetIds: targetIds)
                } label: {
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(nsImage: coloredCircleImage(color: tabColorSwatchColor(for: entry.hex)))
                    }
                }
            }
        }

        if let copyableSidebarSSHError = workspaceSnapshot.copyableSidebarSSHError {
            Button(String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")) {
                copyTextToPasteboard(copyableSidebarSSHError)
            }
        }

        Divider()

        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveBy(-1)
        }
        .disabled(index == 0)

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveBy(1)
        }
        .disabled(index >= tabManager.tabs.count - 1)

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")) {
            tabManager.moveTabsToTop(Set(targetIds))
            syncSelectionAfterMutation()
        }
        .disabled(targetIds.isEmpty)

        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowMoveTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        let moveMenuTitle = targetIds.count > 1
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")
        Menu(moveMenuTitle) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                moveWorkspacesToNewWindow(targetIds)
            }
            .disabled(targetIds.isEmpty)

            if !windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(windowMoveTargets) { target in
                Button(target.label) {
                    moveWorkspaces(targetIds, toWindow: target.windowId)
                }
                .disabled(target.isCurrentWindow || targetIds.isEmpty)
            }
        }
        .disabled(targetIds.isEmpty)

        Divider()

        if let key = closeWorkspaceShortcut.keyEquivalent {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .keyboardShortcut(key, modifiers: closeWorkspaceShortcut.eventModifiers)
            .disabled(targetIds.isEmpty)
        } else {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .disabled(targetIds.isEmpty)
        }

        Button(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")) {
            closeOtherTabs(targetIds)
        }
        .disabled(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count)

        Button(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")) {
            closeTabsBelow(tabId: tab.id)
        }
        .disabled(index >= tabManager.tabs.count - 1)

        Button(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")) {
            closeTabsAbove(tabId: tab.id)
        }
        .disabled(index == 0)

        Divider()

        Button(markReadLabel) {
            markTabsRead(targetIds)
        }
        .disabled(!hasUnreadNotifications(in: targetIds))

        Button(markUnreadLabel) {
            markTabsUnread(targetIds)
        }
        .disabled(!hasReadNotifications(in: targetIds))

        Button(clearLatestNotificationLabel) {
            clearLatestNotifications(targetIds)
        }
        .disabled(!hasLatestNotifications(in: targetIds))
    }

    private var backgroundColor: Color {
        let style = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            isActive: isActive,
            isMultiSelected: isMultiSelected,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme,
            sidebarSelectionColorHex: sidebarSelectionColorHex
        )
        guard let color = style.color else { return .clear }
        return Color(nsColor: color).opacity(style.opacity)
    }

    private var railColor: Color {
        explicitRailColor ?? .clear
    }

    private var explicitRailColor: Color? {
        guard let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme
        ) else {
            return nil
        }
        return Color(nsColor: railColor).opacity(0.95)
    }

    private func tabColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }

    private var showsCenteredTopDropIndicator: Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        if indicator.tabId == tab.id && indicator.edge == .top {
            return true
        }

        guard indicator.edge == .bottom,
              let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }),
              currentIndex > 0
        else {
            return false
        }
        return tabManager.tabs[currentIndex - 1].id == indicator.tabId
    }

    private var accessibilityTitle: String {
        String(localized: "accessibility.workspacePosition", defaultValue: "\(workspaceSnapshot.title), workspace \(index + 1) of \(accessibilityWorkspaceCount)")
    }

    private func moveBy(_ delta: Int) {
        let targetIndex = index + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        guard tabManager.reorderWorkspace(tabId: tab.id, toIndex: targetIndex) else { return }
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == tab.id }
        tabManager.selectTab(tab)
        setSelectionToTabs()
    }

    private func updateSelection() {
        #if DEBUG
        let mods = NSEvent.modifierFlags
        var modStr = ""
        if mods.contains(.command) { modStr += "cmd " }
        if mods.contains(.shift) { modStr += "shift " }
        if mods.contains(.option) { modStr += "opt " }
        if mods.contains(.control) { modStr += "ctrl " }
        dlog("sidebar.select workspace=\(tab.id.uuidString.prefix(5)) modifiers=\(modStr.isEmpty ? "none" : modStr.trimmingCharacters(in: .whitespaces))")
        #endif
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == tab.id

        if isShift, let lastIndex = lastSidebarSelectionIndex {
            let lower = min(lastIndex, index)
            let upper = max(lastIndex, index)
            let rangeIds = tabManager.tabs[lower...upper].map { $0.id }
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedTabIds.contains(tab.id) {
                selectedTabIds.remove(tab.id)
            } else {
                selectedTabIds.insert(tab.id)
            }
        } else {
            selectedTabIds = [tab.id]
        }

        lastSidebarSelectionIndex = index
        tabManager.selectTab(tab)
        if wasSelected, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: tab.id,
                surfaceId: tabManager.focusedSurfaceId(for: tab.id)
            )
        }
        setSelectionToTabs()
    }

    private func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(targetIds, allowPinned: allowPinned)
        syncSelectionAfterMutation()
    }

    private func closeOtherTabs(_ targetIds: [UUID]) {
        let keepIds = Set(targetIds)
        let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsBelow(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsAbove(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markRead(forTabId: id)
        }
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markUnread(forTabId: id)
        }
    }

    private func clearLatestNotifications(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.clearLatestNotification(forTabId: id)
        }
    }

    private func hasUnreadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && !$0.isRead }
    }

    private func hasReadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && $0.isRead }
    }

    private func hasLatestNotifications(in targetIds: [UUID]) -> Bool {
        targetIds.contains { notificationStore.latestNotification(forTabId: $0) != nil }
    }

    private func syncSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map { $0.id })
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
    }

    private var remoteStateHelpText: String {
        let target = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tab.remoteConnectionState {
        case .connected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connected",
                    defaultValue: "SSH connected to %@"
                ),
                locale: .current,
                target
            )
        case .connecting:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connecting",
                    defaultValue: "SSH connecting to %@"
                ),
                locale: .current,
                target
            )
        case .error:
            if let detail, !detail.isEmpty {
                return String(
                    format: String(
                        localized: "sidebar.remote.help.errorWithDetail",
                        defaultValue: "SSH error for %@: %@"
                    ),
                    locale: .current,
                    target,
                    detail
                )
            }
            return String(
                format: String(
                    localized: "sidebar.remote.help.error",
                    defaultValue: "SSH error for %@"
                ),
                locale: .current,
                target
            )
        case .disconnected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.disconnected",
                    defaultValue: "SSH disconnected from %@"
                ),
                locale: .current,
                target
            )
        }
    }

    private func makeWorkspaceSnapshot() -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let detailVisibility = visibleAuxiliaryDetails
        let orderedPanelIds: [UUID]? = (detailVisibility.showsBranchDirectory || detailVisibility.showsPullRequests)
            ? tab.sidebarOrderedPanelIds()
            : nil
        let compactGitBranchSummaryText: String? = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  sidebarShowGitBranch,
                  let orderedPanelIds else {
                return nil
            }
            return gitBranchSummaryText(orderedPanelIds: orderedPanelIds)
        }()
        let compactDirectorySummaryText: String? = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return nil
            }
            return directorySummaryText(orderedPanelIds: orderedPanelIds)
        }()
        let compactBranchDirectoryRow = branchDirectoryRow(
            gitSummary: compactGitBranchSummaryText,
            directorySummary: compactDirectorySummaryText
        )
        let branchDirectoryLines: [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] = {
            guard detailVisibility.showsBranchDirectory,
                  sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return []
            }
            return verticalBranchDirectoryLines(orderedPanelIds: orderedPanelIds)
        }()
        let branchLinesContainBranch = sidebarShowGitBranch && branchDirectoryLines.contains { $0.branch != nil }
        let pullRequestRows: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] = {
            guard detailVisibility.showsPullRequests, let orderedPanelIds else { return [] }
            return pullRequestDisplays(orderedPanelIds: orderedPanelIds)
        }()

        return SidebarWorkspaceSnapshotBuilder.Snapshot(
            title: tab.title,
            customDescription: tab.customDescription,
            isPinned: tab.isPinned,
            customColorHex: tab.customColor,
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            copyableSidebarSSHError: copyableSidebarSSHError,
            metadataEntries: detailVisibility.showsMetadata ? tab.sidebarStatusEntriesInDisplayOrder() : [],
            metadataBlocks: detailVisibility.showsMetadata ? tab.sidebarMetadataBlocksInDisplayOrder() : [],
            latestLog: detailVisibility.showsLog ? tab.logEntries.last : nil,
            progress: detailVisibility.showsProgress ? tab.progress : nil,
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactBranchDirectoryRow: compactBranchDirectoryRow,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: detailVisibility.showsPorts ? tab.listeningPorts : []
        )
    }
    private func moveWorkspaces(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard !orderedWorkspaceIds.isEmpty else { return }

        for (index, workspaceId) in orderedWorkspaceIds.enumerated() {
            let shouldFocus = index == orderedWorkspaceIds.count - 1
            _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: shouldFocus)
        }

        selectedTabIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    private func moveWorkspacesToNewWindow(_ workspaceIds: [UUID]) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstWorkspaceId = orderedWorkspaceIds.first else { return }

        let shouldFocusImmediately = orderedWorkspaceIds.count == 1
        guard let newWindowId = app.moveWorkspaceToNewWindow(workspaceId: firstWorkspaceId, focus: shouldFocusImmediately) else {
            return
        }

        if orderedWorkspaceIds.count > 1 {
            for workspaceId in orderedWorkspaceIds.dropFirst() {
                _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: newWindowId, focus: false)
            }
            if let finalWorkspaceId = orderedWorkspaceIds.last {
                _ = app.moveWorkspaceToWindow(workspaceId: finalWorkspaceId, windowId: newWindowId, focus: true)
            }
        }

        selectedTabIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    // latestNotificationText is now passed as a parameter from the parent view
    // to avoid subscribing to notificationStore changes in every TabItemView.

    private func branchDirectoryRow(
        gitSummary: String?,
        directorySummary: String?
    ) -> String? {
        var parts: [String] = []

        if let gitSummary {
            parts.append(gitSummary)
        }

        if let directorySummary {
            parts.append(directorySummary)
        }

        let result = parts.joined(separator: " · ")
        return result.isEmpty ? nil : result
    }

    private func gitBranchSummaryText(orderedPanelIds: [UUID]) -> String? {
        let lines = gitBranchSummaryLines(orderedPanelIds: orderedPanelIds)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private func gitBranchSummaryLines(orderedPanelIds: [UUID]) -> [String] {
        tab.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { branch in
            "\(branch.branch)\(branch.isDirty ? "*" : "")"
        }
    }

    private func verticalBranchDirectoryLines(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] {
        let entries = tab.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        let home = SidebarPathFormatter.homeDirectoryPath
        return entries.compactMap { entry in
            let branchText: String? = {
                guard sidebarShowGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()

            let directoryText: String? = {
                guard let directory = entry.directory else { return nil }
                let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
                return shortened.isEmpty ? nil : shortened
            }()

            switch (branchText, directoryText) {
            case let (branch?, directory?):
                return SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(branch: branch, directory: directory)
            case let (branch?, nil):
                return SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(branch: branch, directory: nil)
            case let (nil, directory?):
                return SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(branch: nil, directory: directory)
            default:
                return nil
            }
        }
    }

    private func directorySummaryText(orderedPanelIds: [UUID]) -> String? {
        let home = SidebarPathFormatter.homeDirectoryPath
        let entries = tab.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds).compactMap { directory in
            let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
            return shortened.isEmpty ? nil : shortened
        }
        return entries.isEmpty ? nil : entries.joined(separator: " | ")
    }

    private func pullRequestDisplays(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] {
        tab.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map { pullRequest in
            SidebarWorkspaceSnapshotBuilder.PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                isStale: pullRequest.isStale
            )
        }
    }

    private var pullRequestForegroundColor: Color {
        isActive ? .white.opacity(0.75) : .secondary
    }

    private func openPullRequestLink(_ url: URL) {
        updateSelection()
        if openSidebarPullRequestLinksInCmuxBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openPortLink(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        updateSelection()
        if openSidebarPortLinksInCmuxBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    private func logLevelIcon(_ level: SidebarLogLevel) -> String {
        switch level {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func logLevelColor(_ level: SidebarLogLevel, isActive: Bool) -> Color {
        if isActive {
            switch level {
            case .info:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.5))
            case .progress:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.8))
            case .success:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.9))
            case .warning:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.9))
            case .error:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.9))
            }
        }
        switch level {
        case .info: return .secondary
        case .progress: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func shortenPath(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }

    private struct PullRequestStatusIcon: View {
        let status: SidebarPullRequestStatus
        let color: Color
        private static let frameSize: CGFloat = 12

        var body: some View {
            switch status {
            case .open:
                PullRequestOpenIcon(color: color)
            case .merged:
                PullRequestMergedIcon(color: color)
            case .closed:
                Image(systemName: "xmark.circle")
                    .font(.system(size: 7, weight: .regular))
                    .foregroundColor(color)
                    .frame(width: Self.frameSize, height: Self.frameSize)
            }
        }
    }

    private struct PullRequestOpenIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 3.0, y: 4.8))
                    path.addLine(to: CGPoint(x: 3.0, y: 9.2))

                    path.move(to: CGPoint(x: 4.8, y: 3.0))
                    path.addLine(to: CGPoint(x: 9.4, y: 3.0))
                    path.addLine(to: CGPoint(x: 11.0, y: 4.6))
                    path.addLine(to: CGPoint(x: 11.0, y: 9.2))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 11.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private struct PullRequestMergedIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 4.6, y: 4.6))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                    path.addLine(to: CGPoint(x: 9.2, y: 7.0))

                    path.move(to: CGPoint(x: 4.6, y: 9.4))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 7.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private func applyTabColor(_ hex: String?, targetIds: [UUID]) {
        for targetId in targetIds {
            tabManager.setTabColor(tabId: targetId, color: hex)
        }
    }

    private func toggleWorkspaceTerminalScrollBarHidden(targetIds: [UUID]) {
        let currentlyHidden = !targetIds.isEmpty && targetIds.allSatisfy { targetId in
            tabManager.tabs.first(where: { $0.id == targetId })?.terminalScrollBarHidden == true
        }
        let hideScrollBar = !currentlyHidden
        for targetId in targetIds {
            tabManager.setWorkspaceTerminalScrollBarHidden(tabId: targetId, hidden: hideScrollBar)
        }
    }

    private func promptCustomColor(targetIds: [UUID]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")

        let seed = tab.customColor ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        applyTabColor(normalized, targetIds: targetIds)
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
        }
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
    }

    private func beginWorkspaceDescriptionEditFromContextMenu() {
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = index
        tabManager.selectTab(tab)
        setSelectionToTabs()
        _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
    }
}

private struct SidebarWorkspaceDescriptionText: View {
    let markdown: String
    let isActive: Bool

    var body: some View {
        let renderedMarkdown = SidebarMarkdownRenderer.renderWorkspaceDescription(markdown)
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
            } else {
                Text(markdown)
            }
        }
        .font(.system(size: 10.5))
        .foregroundColor(foregroundColor)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("SidebarWorkspaceDescriptionText")
        .accessibilityLabel(accessibilityText(renderedMarkdown: renderedMarkdown))
        .onAppear {
#if DEBUG
            let newlineCount = markdown.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "sidebar.description.render workspaceState=appear " +
                "len=\((markdown as NSString).length) " +
                "newlines=\(newlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(markdown))\""
            )
#endif
        }
        .onChange(of: markdown) { newValue in
#if DEBUG
            let newlineCount = newValue.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "sidebar.description.render workspaceState=change " +
                "len=\((newValue as NSString).length) " +
                "newlines=\(newlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(newValue))\""
            )
#endif
        }
    }

    private var foregroundColor: Color {
        isActive ? .white.opacity(0.84) : .secondary.opacity(0.95)
    }

    private func accessibilityText(renderedMarkdown: AttributedString?) -> String {
        if let renderedMarkdown {
            return String(renderedMarkdown.characters)
        }
        return markdown
    }
}

enum SidebarMarkdownRenderer {
    static func renderWorkspaceDescription(_ markdown: String) -> AttributedString? {
        try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}

private struct SidebarMetadataRows: View {
    let entries: [SidebarStatusEntry]
    let isActive: Bool
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedEntryLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleEntries, id: \.key) { entry in
                SidebarMetadataEntryRow(entry: entry, isActive: isActive, onFocus: onFocus)
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less") : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? activeSecondaryTextColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeHelp(helpText)
    }

    private var activeSecondaryTextColor: Color {
        Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.65))
    }

    private var visibleEntries: [SidebarStatusEntry] {
        guard !isExpanded, entries.count > collapsedEntryLimit else { return entries }
        return Array(entries.prefix(collapsedEntryLimit))
    }

    private var helpText: String {
        entries.map { entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? entry.key : trimmed
        }
        .joined(separator: "\n")
    }

    private var shouldShowToggle: Bool {
        entries.count > collapsedEntryLimit
    }
}

private struct SidebarMetadataEntryRow: View {
    let entry: SidebarStatusEntry
    let isActive: Bool
    let onFocus: () -> Void

    var body: some View {
        Group {
            if let url = entry.url {
                Button {
                    onFocus()
                    NSWorkspace.shared.open(url)
                } label: {
                    rowContent(underlined: true)
                }
                .buttonStyle(.plain)
                .safeHelp(url.absoluteString)
            } else {
                rowContent(underlined: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onFocus() }
            }
        }
    }

    @ViewBuilder
    private func rowContent(underlined: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon = iconView {
                icon
                    .foregroundColor(foregroundColor.opacity(0.95))
            }
            metadataText(underlined: underlined)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foregroundColor: Color {
        if isActive,
           let raw = entry.color,
           Color(hex: raw) != nil {
            return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.95))
        }
        if let raw = entry.color, let explicit = Color(hex: raw) {
            return explicit
        }
        return isActive ? .white.opacity(0.8) : .secondary
    }

    private var iconView: AnyView? {
        guard let iconRaw = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !iconRaw.isEmpty else {
            return nil
        }
        if iconRaw.hasPrefix("emoji:") {
            let value = String(iconRaw.dropFirst("emoji:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).font(.system(size: 9)))
        }
        if iconRaw.hasPrefix("text:") {
            let value = String(iconRaw.dropFirst("text:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).font(.system(size: 8, weight: .semibold)))
        }
        let symbolName: String
        if iconRaw.hasPrefix("sf:") {
            symbolName = String(iconRaw.dropFirst("sf:".count))
        } else {
            symbolName = iconRaw
        }
        guard !symbolName.isEmpty else { return nil }
        return AnyView(Image(systemName: symbolName).font(.system(size: 8, weight: .medium)))
    }

    @ViewBuilder
    private func metadataText(underlined: Bool) -> some View {
        let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? entry.key : trimmed
        if entry.format == .markdown,
           let attributed = try? AttributedString(
                markdown: display,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            Text(attributed)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        } else {
            Text(display)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        }
    }
}

private struct SidebarMetadataMarkdownBlocks: View {
    let blocks: [SidebarMetadataBlock]
    let isActive: Bool
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedBlockLimit = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visibleBlocks, id: \.key) { block in
                SidebarMetadataMarkdownBlockRow(
                    block: block,
                    isActive: isActive,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLessDetails", defaultValue: "Show less details") : String(localized: "sidebar.metadata.showMoreDetails", defaultValue: "Show more details")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? .white.opacity(0.65) : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visibleBlocks: [SidebarMetadataBlock] {
        guard !isExpanded, blocks.count > collapsedBlockLimit else { return blocks }
        return Array(blocks.prefix(collapsedBlockLimit))
    }

    private var shouldShowToggle: Bool {
        blocks.count > collapsedBlockLimit
    }
}

private struct SidebarMetadataMarkdownBlockRow: View {
    let block: SidebarMetadataBlock
    let isActive: Bool
    let onFocus: () -> Void

    @State private var renderedMarkdown: AttributedString?

    var body: some View {
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
                    .foregroundColor(foregroundColor)
            } else {
                Text(block.markdown)
                    .foregroundColor(foregroundColor)
            }
        }
        .font(.system(size: 10))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onAppear(perform: renderMarkdown)
        .onChange(of: block.markdown) { _ in
            renderMarkdown()
        }
    }

    private var foregroundColor: Color {
        isActive ? .white.opacity(0.8) : .secondary
    }

    private func renderMarkdown() {
        renderedMarkdown = try? AttributedString(
            markdown: block.markdown,
            options: .init(interpretedSyntax: .full)
        )
    }
}

enum SidebarDropEdge: Equatable {
    case top
    case bottom
}

struct SidebarDropIndicator: Equatable {
    let tabId: UUID?
    let edge: SidebarDropEdge
}

enum SidebarDropPlanner {
    static func indicator(
        draggedTabId: UUID?,
        targetTabId: UUID?,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        pointerY: CGFloat? = nil,
        targetHeight: CGFloat? = nil
    ) -> SidebarDropIndicator? {
        guard tabIds.count > 1, let draggedTabId else { return nil }
        guard let fromIndex = tabIds.firstIndex(of: draggedTabId) else { return nil }

        let insertionPosition: Int
        if let targetTabId {
            guard let targetTabIndex = tabIds.firstIndex(of: targetTabId) else { return nil }
            let edge: SidebarDropEdge
            if let pointerY, let targetHeight {
                edge = edgeForPointer(locationY: pointerY, targetHeight: targetHeight)
            } else {
                edge = preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds)
            }
            insertionPosition = (edge == .bottom) ? targetTabIndex + 1 : targetTabIndex
        } else {
            insertionPosition = tabIds.count
        }

        let legalInsertionPosition = legalInsertionPosition(
            draggedTabId: draggedTabId,
            proposedInsertionPosition: insertionPosition,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds
        )
        let legalTargetIndex = resolvedTargetIndex(
            from: fromIndex,
            insertionPosition: legalInsertionPosition,
            totalCount: tabIds.count
        )
        guard legalTargetIndex != fromIndex else { return nil }
        return indicatorForInsertionPosition(legalInsertionPosition, tabIds: tabIds)
    }

    static func targetIndex(
        draggedTabId: UUID,
        targetTabId: UUID?,
        indicator: SidebarDropIndicator?,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>
    ) -> Int? {
        guard let fromIndex = tabIds.firstIndex(of: draggedTabId) else { return nil }

        let insertionPosition: Int
        if let indicator, let indicatorInsertion = insertionPositionForIndicator(indicator, tabIds: tabIds) {
            insertionPosition = indicatorInsertion
        } else if let targetTabId {
            guard let targetTabIndex = tabIds.firstIndex(of: targetTabId) else { return nil }
            let edge = (indicator?.tabId == targetTabId)
                ? (indicator?.edge ?? preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds))
                : preferredEdge(fromIndex: fromIndex, targetTabId: targetTabId, tabIds: tabIds)
            insertionPosition = (edge == .bottom) ? targetTabIndex + 1 : targetTabIndex
        } else {
            insertionPosition = tabIds.count
        }

        let legalInsertionPosition = legalInsertionPosition(
            draggedTabId: draggedTabId,
            proposedInsertionPosition: insertionPosition,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds
        )
        return resolvedTargetIndex(from: fromIndex, insertionPosition: legalInsertionPosition, totalCount: tabIds.count)
    }

    private static func indicatorForInsertionPosition(_ insertionPosition: Int, tabIds: [UUID]) -> SidebarDropIndicator {
        let clampedInsertion = max(0, min(insertionPosition, tabIds.count))
        if clampedInsertion >= tabIds.count {
            return SidebarDropIndicator(tabId: nil, edge: .bottom)
        }
        return SidebarDropIndicator(tabId: tabIds[clampedInsertion], edge: .top)
    }

    private static func insertionPositionForIndicator(_ indicator: SidebarDropIndicator, tabIds: [UUID]) -> Int? {
        if let tabId = indicator.tabId {
            guard let targetTabIndex = tabIds.firstIndex(of: tabId) else { return nil }
            return indicator.edge == .bottom ? targetTabIndex + 1 : targetTabIndex
        }
        return tabIds.count
    }

    private static func preferredEdge(fromIndex: Int, targetTabId: UUID, tabIds: [UUID]) -> SidebarDropEdge {
        guard let targetIndex = tabIds.firstIndex(of: targetTabId) else { return .top }
        return fromIndex < targetIndex ? .bottom : .top
    }

    private static func legalInsertionPosition(
        draggedTabId: UUID,
        proposedInsertionPosition: Int,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>
    ) -> Int {
        let clampedInsertion = max(0, min(proposedInsertionPosition, tabIds.count))
        guard !pinnedTabIds.isEmpty else { return clampedInsertion }

        let pinnedCount = tabIds.reduce(into: 0) { count, tabId in
            if pinnedTabIds.contains(tabId) {
                count += 1
            }
        }
        guard pinnedCount > 0 else { return clampedInsertion }

        if pinnedTabIds.contains(draggedTabId) {
            return min(clampedInsertion, pinnedCount)
        }
        return max(clampedInsertion, pinnedCount)
    }

    static func edgeForPointer(locationY: CGFloat, targetHeight: CGFloat) -> SidebarDropEdge {
        guard targetHeight > 0 else { return .top }
        let clampedY = min(max(locationY, 0), targetHeight)
        return clampedY < (targetHeight / 2) ? .top : .bottom
    }

    private static func resolvedTargetIndex(from sourceIndex: Int, insertionPosition: Int, totalCount: Int) -> Int {
        let clampedInsertion = max(0, min(insertionPosition, totalCount))
        let adjusted = clampedInsertion > sourceIndex ? clampedInsertion - 1 : clampedInsertion
        return max(0, min(adjusted, max(0, totalCount - 1)))
    }
}

enum SidebarAutoScrollDirection: Equatable {
    case up
    case down
}

struct SidebarAutoScrollPlan: Equatable {
    let direction: SidebarAutoScrollDirection
    let pointsPerTick: CGFloat
}

enum SidebarDragAutoScrollPlanner {
    static let edgeInset: CGFloat = 44
    static let minStep: CGFloat = 2
    static let maxStep: CGFloat = 12

    static func plan(
        distanceToTop: CGFloat,
        distanceToBottom: CGFloat,
        edgeInset: CGFloat = SidebarDragAutoScrollPlanner.edgeInset,
        minStep: CGFloat = SidebarDragAutoScrollPlanner.minStep,
        maxStep: CGFloat = SidebarDragAutoScrollPlanner.maxStep
    ) -> SidebarAutoScrollPlan? {
        guard edgeInset > 0, maxStep >= minStep else { return nil }
        if distanceToTop <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToTop) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .up, pointsPerTick: step)
        }
        if distanceToBottom <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToBottom) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .down, pointsPerTick: step)
        }
        return nil
    }
}

@MainActor
private final class SidebarDragAutoScrollController: ObservableObject {
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var activePlan: SidebarAutoScrollPlan?

    func attach(scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    func updateFromDragLocation() {
        guard let scrollView else {
            stop()
            return
        }
        guard let plan = plan(for: scrollView) else {
            stop()
            return
        }
        activePlan = plan
        startTimerIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activePlan = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons != 0 else {
            stop()
            return
        }
        guard let scrollView else {
            stop()
            return
        }

        // AppKit drag/drop autoscroll guidance recommends autoscroll(with:)
        // when periodic drag updates are available; use it first.
        if applyNativeAutoscroll(to: scrollView) {
            activePlan = plan(for: scrollView)
            if activePlan == nil {
                stop()
            }
            return
        }

        activePlan = self.plan(for: scrollView)
        guard let plan = activePlan else {
            stop()
            return
        }
        _ = apply(plan: plan, to: scrollView)
    }

    private func applyNativeAutoscroll(to scrollView: NSScrollView) -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break
        default:
            return false
        }

        let clipView = scrollView.contentView
        let didScroll = clipView.autoscroll(with: event)
        if didScroll {
            scrollView.reflectScrolledClipView(clipView)
        }
        return didScroll
    }

    private func distancesToEdges(mousePoint: CGPoint, viewportHeight: CGFloat, isFlipped: Bool) -> (top: CGFloat, bottom: CGFloat) {
        if isFlipped {
            return (top: mousePoint.y, bottom: viewportHeight - mousePoint.y)
        }
        return (top: viewportHeight - mousePoint.y, bottom: mousePoint.y)
    }

    private func planForMousePoint(_ mousePoint: CGPoint, in clipView: NSClipView) -> SidebarAutoScrollPlan? {
        let viewportHeight = clipView.bounds.height
        guard viewportHeight > 0 else { return nil }

        let distances = distancesToEdges(mousePoint: mousePoint, viewportHeight: viewportHeight, isFlipped: clipView.isFlipped)
        return SidebarDragAutoScrollPlanner.plan(distanceToTop: distances.top, distanceToBottom: distances.bottom)
    }

    private func mousePoint(in clipView: NSClipView) -> CGPoint {
        let mouseInWindow = clipView.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        return clipView.convert(mouseInWindow, from: nil)
    }

    private func currentPlan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        let clipView = scrollView.contentView
        let mouse = mousePoint(in: clipView)
        return planForMousePoint(mouse, in: clipView)
    }

    private func plan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        currentPlan(for: scrollView)
    }

    private func apply(plan: SidebarAutoScrollPlan, to scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        let clipView = scrollView.contentView
        let maxOriginY = max(0, documentView.bounds.height - clipView.bounds.height)
        guard maxOriginY > 0 else { return false }

        let directionMultiplier: CGFloat = (plan.direction == .down) ? 1 : -1
        let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
        let delta = directionMultiplier * flippedMultiplier * plan.pointsPerTick
        let currentY = clipView.bounds.origin.y
        let targetY = min(max(currentY + delta, 0), maxOriginY)
        guard abs(targetY - currentY) > 0.01 else { return false }

        clipView.scroll(to: CGPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

private enum SidebarTabDragPayload {
    static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    private static let prefix = "cmux.sidebar-tab."

    static func provider(for tabId: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = "\(prefix)\(tabId.uuidString)"
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(payload.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
}

private enum BonsplitTabDragPayload {
    static let typeIdentifier = "com.splittabbar.tabtransfer"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    private static let currentProcessId = Int32(ProcessInfo.processInfo.processIdentifier)

    struct Transfer: Decodable {
        struct TabInfo: Decodable {
            let id: UUID
        }

        let tab: TabInfo
        let sourcePaneId: UUID
        let sourceProcessId: Int32

        private enum CodingKeys: String, CodingKey {
            case tab
            case sourcePaneId
            case sourceProcessId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.tab = try container.decode(TabInfo.self, forKey: .tab)
            self.sourcePaneId = try container.decode(UUID.self, forKey: .sourcePaneId)
            // Legacy payloads won't include this field. Treat as foreign process.
            self.sourceProcessId = try container.decodeIfPresent(Int32.self, forKey: .sourceProcessId) ?? -1
        }
    }

    private static func isCurrentProcessTransfer(_ transfer: Transfer) -> Bool {
        transfer.sourceProcessId == currentProcessId
    }

    static func currentTransfer() -> Transfer? {
        let pasteboard = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(typeIdentifier)

        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        if let raw = pasteboard.string(forType: type),
           let data = raw.data(using: .utf8),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        return nil
    }
}

private struct SidebarBonsplitTabDropDelegate: DropDelegate {
    let targetWorkspaceId: UUID
    let tabManager: TabManager
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [BonsplitTabDragPayload.typeIdentifier]) else { return false }
        return BonsplitTabDragPayload.currentTransfer() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let transfer = BonsplitTabDragPayload.currentTransfer(),
              let app = AppDelegate.shared else {
            return false
        }

        if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
           source.workspaceId == targetWorkspaceId {
            syncSidebarSelection()
            return true
        }

        guard app.moveBonsplitTab(
            tabId: transfer.tab.id,
            toWorkspace: targetWorkspaceId,
            focus: true,
            focusWindow: true
        ) else {
            return false
        }

        selectedTabIds = [targetWorkspaceId]
        syncSidebarSelection()
        return true
    }

    private func syncSidebarSelection() {
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}

private struct SidebarTabDropDelegate: DropDelegate {
    let targetTabId: UUID?
    let tabManager: TabManager
    @Binding var draggedTabId: UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?

    func validateDrop(info: DropInfo) -> Bool {
        let hasType = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        let hasDrag = draggedTabId != nil
        #if DEBUG
        dlog("sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") hasType=\(hasType) hasDrag=\(hasDrag)")
        #endif
        return hasType && hasDrag
    }

    func dropEntered(info: DropInfo) {
        #if DEBUG
        dlog("sidebar.dropEntered target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        dlog("sidebar.dropExited target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
#endif
        if dropIndicator?.tabId == targetTabId {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
#if DEBUG
        dlog(
            "sidebar.dropUpdated target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "indicator=\(debugIndicator(dropIndicator))"
        )
#endif
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        #if DEBUG
        dlog("sidebar.drop target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        guard let draggedTabId else {
#if DEBUG
            dlog("sidebar.drop.abort reason=missingDraggedTab")
#endif
            return false
        }
        guard let fromIndex = tabManager.tabs.firstIndex(where: { $0.id == draggedTabId }) else {
#if DEBUG
            dlog("sidebar.drop.abort reason=draggedTabMissing tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }
        let tabIds = tabManager.tabs.map(\.id)
        guard let targetIndex = SidebarDropPlanner.targetIndex(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
            indicator: dropIndicator,
            tabIds: tabIds,
            pinnedTabIds: Set(tabManager.tabs.filter(\.isPinned).map(\.id))
        ) else {
#if DEBUG
            dlog(
                "sidebar.drop.abort reason=noTargetIndex tab=\(draggedTabId.uuidString.prefix(5)) " +
                "target=\(targetTabId?.uuidString.prefix(5) ?? "end") indicator=\(debugIndicator(dropIndicator))"
            )
#endif
            return false
        }

        guard fromIndex != targetIndex else {
#if DEBUG
            dlog("sidebar.drop.noop from=\(fromIndex) to=\(targetIndex)")
#endif
            syncSidebarSelection()
            return true
        }

#if DEBUG
        dlog("sidebar.drop.commit tab=\(draggedTabId.uuidString.prefix(5)) from=\(fromIndex) to=\(targetIndex)")
#endif
        _ = tabManager.reorderWorkspace(tabId: draggedTabId, toIndex: targetIndex)
        if let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
            syncSidebarSelection(preferredSelectedTabId: selectedId)
        } else {
            selectedTabIds = []
            syncSidebarSelection()
        }
        return true
    }

    private func updateDropIndicator(for info: DropInfo) {
        let tabIds = tabManager.tabs.map(\.id)
        let pinnedTabIds = Set(tabManager.tabs.filter(\.isPinned).map(\.id))
        let nextIndicator = SidebarDropPlanner.indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            pointerY: targetTabId == nil ? nil : info.location.y,
            targetHeight: targetRowHeight
        )
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? tabManager.selectedTabId
        if let selectedId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        } else {
            lastSidebarSelectionIndex = nil
        }
    }

    private func debugIndicator(_ indicator: SidebarDropIndicator?) -> String {
        guard let indicator else { return "nil" }
        let tabText = indicator.tabId.map { String($0.uuidString.prefix(5)) } ?? "end"
        return "\(tabText):\(indicator.edge == .top ? "top" : "bottom")"
    }
}

private struct MiddleClickCapture: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickCaptureView {
        let view = MiddleClickCaptureView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: MiddleClickCaptureView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}

private final class MiddleClickCaptureView: NSView {
    var onMiddleClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept middle-click so left-click selection and right-click context menus
        // continue to hit-test through to SwiftUI/AppKit normally.
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown,
              event.buttonNumber == 2 else {
            return nil
        }
        return self
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick?()
    }
}

enum SidebarSelection {
    case tabs
    case notifications
}

private struct ClearScrollBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background(ScrollBackgroundClearer())
        } else {
            content
                .background(ScrollBackgroundClearer())
        }
    }
}

private struct ScrollBackgroundClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = findScrollView(startingAt: nsView) else { return }
            // Clear all backgrounds and mark as non-opaque for transparency
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.wantsLayer = true
            scrollView.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView.layer?.isOpaque = false

            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
            scrollView.contentView.wantsLayer = true
            scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView.contentView.layer?.isOpaque = false

            if let docView = scrollView.documentView {
                docView.wantsLayer = true
                docView.layer?.backgroundColor = NSColor.clear.cgColor
                docView.layer?.isOpaque = false
            }
        }
    }

    private func findScrollView(startingAt view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            current = candidate.superview
        }
        return nil
    }
}

private struct DraggableFolderIcon: View {
    let directory: String

    var body: some View {
        DraggableFolderIconRepresentable(directory: directory)
            .frame(width: 16, height: 16)
            .safeHelp(String(localized: "sidebar.folderIcon.dragHint", defaultValue: "Drag to open in Finder or another app"))
            .onTapGesture(count: 2) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
            }
    }
}

private struct DraggableFolderIconRepresentable: NSViewRepresentable {
    let directory: String

    func makeNSView(context: Context) -> DraggableFolderNSView {
        DraggableFolderNSView(directory: directory)
    }

    func updateNSView(_ nsView: DraggableFolderNSView, context: Context) {
        nsView.directory = directory
        nsView.updateIcon()
    }
}

final class DraggableFolderNSView: NSView, NSDraggingSource {
    private final class FolderIconImageView: NSImageView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    var directory: String
    private var imageView: FolderIconImageView!
    private var previousWindowMovableState: Bool?
    private weak var suppressedWindow: NSWindow?
    private var hasActiveDragSession = false
    private var didArmWindowDragSuppression = false

    private func formatPoint(_ point: NSPoint) -> String {
        String(format: "(%.1f,%.1f)", point.x, point.y)
    }

    init(directory: String) {
        self.directory = directory
        super.init(frame: .zero)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private func setupImageView() {
        imageView = FolderIconImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateIcon()
    }

    func updateIcon() {
        let icon = NSWorkspace.shared.icon(forFile: directory)
        icon.size = NSSize(width: 16, height: 16)
        imageView.image = icon
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .link] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hasActiveDragSession = false
        restoreWindowMovableStateIfNeeded()
        #if DEBUG
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.dragEnd dir=\(directory) operation=\(operation.rawValue) screen=\(formatPoint(screenPoint)) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let hit = super.hitTest(point)
        #if DEBUG
        let hitDesc = hit.map { String(describing: type(of: $0)) } ?? "nil"
        let imageHit = (hit === imageView)
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        dlog("folder.hitTest point=\(formatPoint(point)) hit=\(hitDesc) imageViewHit=\(imageHit) returning=DraggableFolderNSView wasMovable=\(wasMovable) nowMovable=\(nowMovable)")
        #endif
        return self
    }

    override func mouseDown(with event: NSEvent) {
        maybeDisableWindowDraggingEarly(trigger: "mouseDown")
        hasActiveDragSession = false
        #if DEBUG
        let localPoint = convert(event.locationInWindow, from: nil)
        let responderDesc = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.mouseDown dir=\(directory) point=\(formatPoint(localPoint)) firstResponder=\(responderDesc) wasMovable=\(wasMovable) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
        let fileURL = URL(fileURLWithPath: directory)
        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)

        let iconImage = NSWorkspace.shared.icon(forFile: directory)
        iconImage.size = NSSize(width: 32, height: 32)
        draggingItem.setDraggingFrame(bounds, contents: iconImage)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        hasActiveDragSession = true
        #if DEBUG
        let itemCount = session.draggingPasteboard.pasteboardItems?.count ?? 0
        dlog("folder.dragStart dir=\(directory) pasteboardItems=\(itemCount)")
        #endif
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // Always restore suppression on mouse-up; drag-session callbacks can be
        // skipped for non-started drags, which would otherwise leave suppression stuck.
        restoreWindowMovableStateIfNeeded()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = buildPathMenu()
        // Pop up menu at bottom-left of icon (like native proxy icon)
        let menuLocation = NSPoint(x: 0, y: bounds.height)
        menu.popUp(positioning: nil, at: menuLocation, in: self)
    }

    private func buildPathMenu() -> NSMenu {
        let menu = NSMenu()
        let url = URL(fileURLWithPath: directory).standardized
        var pathComponents: [URL] = []

        // Build path from current directory up to root
        var current = url
        while current.path != "/" {
            pathComponents.append(current)
            current = current.deletingLastPathComponent()
        }
        pathComponents.append(URL(fileURLWithPath: "/"))

        // Add path components (current dir at top, root at bottom - matches native macOS)
        for pathURL in pathComponents {
            let icon = NSWorkspace.shared.icon(forFile: pathURL.path)
            icon.size = NSSize(width: 16, height: 16)

            let displayName: String
            if pathURL.path == "/" {
                // Use the volume name for root
                if let volumeName = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName {
                    displayName = volumeName
                } else {
                    displayName = String(localized: "sidebar.pathMenu.macintoshHD", defaultValue: "Macintosh HD")
                }
            } else {
                displayName = FileManager.default.displayName(atPath: pathURL.path)
            }

            let item = NSMenuItem(title: displayName, action: #selector(openPathComponent(_:)), keyEquivalent: "")
            item.target = self
            item.image = icon
            item.representedObject = pathURL
            menu.addItem(item)
        }

        // Add computer name at the bottom (like native proxy icon)
        let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let computerIcon = NSImage(named: NSImage.computerName) ?? NSImage()
        computerIcon.size = NSSize(width: 16, height: 16)

        let computerItem = NSMenuItem(title: computerName, action: #selector(openComputer(_:)), keyEquivalent: "")
        computerItem.target = self
        computerItem.image = computerIcon
        menu.addItem(computerItem)

        return menu
    }

    @objc private func openPathComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    @objc private func openComputer(_ sender: NSMenuItem) {
        // Open "Computer" view in Finder (shows all volumes)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/", isDirectory: true))
    }

    private func restoreWindowMovableStateIfNeeded() {
        guard didArmWindowDragSuppression || previousWindowMovableState != nil else { return }
        let targetWindow = suppressedWindow ?? window
        let depthAfter = endWindowDragSuppression(window: targetWindow)
        restoreWindowDragging(window: targetWindow, previousMovableState: previousWindowMovableState)
        self.previousWindowMovableState = nil
        self.suppressedWindow = nil
        self.didArmWindowDragSuppression = false
        #if DEBUG
        let nowMovable = targetWindow.map { String($0.isMovable) } ?? "nil"
        dlog("folder.dragSuppression restore depth=\(depthAfter) nowMovable=\(nowMovable)")
        #endif
    }

    private func maybeDisableWindowDraggingEarly(trigger: String) {
        guard !didArmWindowDragSuppression else { return }
        guard let eventType = NSApp.currentEvent?.type,
              eventType == .leftMouseDown || eventType == .leftMouseDragged else {
            return
        }
        guard let currentWindow = window else { return }

        didArmWindowDragSuppression = true
        suppressedWindow = currentWindow
        let suppressionDepth = beginWindowDragSuppression(window: currentWindow) ?? 0
        if currentWindow.isMovable {
            previousWindowMovableState = temporarilyDisableWindowDragging(window: currentWindow)
        } else {
            previousWindowMovableState = nil
        }
        #if DEBUG
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = String(currentWindow.isMovable)
        dlog(
            "folder.dragSuppression trigger=\(trigger) event=\(eventType) depth=\(suppressionDepth) wasMovable=\(wasMovable) nowMovable=\(nowMovable)"
        )
        #endif
    }
}

func temporarilyDisableWindowDragging(window: NSWindow?) -> Bool? {
    guard let window else { return nil }
    let wasMovable = window.isMovable
    if wasMovable {
        window.isMovable = false
    }
    return wasMovable
}

func restoreWindowDragging(window: NSWindow?, previousMovableState: Bool?) {
    guard let window, let previousMovableState else { return }
    window.isMovable = previousMovableState
}

/// Wrapper view that tries NSGlassEffectView (macOS 26+) when available or requested
private struct SidebarVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let opacity: Double
    let tintColor: NSColor?
    let cornerRadius: CGFloat
    let preferLiquidGlass: Bool

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        opacity: Double = 1.0,
        tintColor: NSColor? = nil,
        cornerRadius: CGFloat = 0,
        preferLiquidGlass: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.opacity = opacity
        self.tintColor = tintColor
        self.cornerRadius = cornerRadius
        self.preferLiquidGlass = preferLiquidGlass
    }

    static var liquidGlassAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    func makeNSView(context: Context) -> NSView {
        // Try NSGlassEffectView if preferred or if we want to test availability
        if preferLiquidGlass, let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassClass.init(frame: .zero)
            glass.autoresizingMask = [.width, .height]
            glass.wantsLayer = true
            return glass
        }

        // Use NSVisualEffectView
        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Configure based on view type
        if nsView.className == "NSGlassEffectView" {
            // NSGlassEffectView configuration via private API
            nsView.alphaValue = max(0.0, min(1.0, opacity))
            nsView.layer?.cornerRadius = cornerRadius
            nsView.layer?.masksToBounds = cornerRadius > 0

            // Try to set tint color via private selector
            if let color = tintColor {
                let selector = NSSelectorFromString("setTintColor:")
                if nsView.responds(to: selector) {
                    nsView.perform(selector, with: color)
                }
            }
        } else if let visualEffect = nsView as? NSVisualEffectView {
            // NSVisualEffectView configuration
            visualEffect.material = material
            visualEffect.blendingMode = blendingMode
            visualEffect.state = state
            visualEffect.alphaValue = max(0.0, min(1.0, opacity))
            visualEffect.layer?.cornerRadius = cornerRadius
            visualEffect.layer?.masksToBounds = cornerRadius > 0
            visualEffect.needsDisplay = true
        }
    }
}


/// Reads the leading inset required to clear traffic lights + left titlebar accessories.
final class TitlebarLeadingInsetPassthroughView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TitlebarLeadingInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = TitlebarLeadingInsetPassthroughView()
        view.setFrameSize(.zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            // Start past the traffic lights
            var leading: CGFloat = 78
            // Add width of all left-aligned titlebar accessories
            for accessory in window.titlebarAccessoryViewControllers
                where accessory.layoutAttribute == .leading || accessory.layoutAttribute == .left {
                leading += accessory.view.frame.width
            }
            leading += 0
            if leading != inset {
                inset = leading
            }
        }
    }
}

/// 1px trailing border on the sidebar, derived from the terminal chrome background
/// using the same logic as bonsplit's TabBarColors.nsColorSeparator:
/// dark bg → lighten RGB by 0.16 at 0.36 alpha; light bg → darken by 0.12 at 0.26 alpha.
private struct SidebarTrailingBorder: View {
    @AppStorage("sidebarMatchTerminalBackground") private var matchTerminalBackground = false
    @State private var separatorColor: NSColor = chromeSeparatorColor()

    var body: some View {
        if matchTerminalBackground {
            Rectangle()
                .fill(Color(nsColor: separatorColor))
                .frame(width: 1)
                .ignoresSafeArea()
                .onAppear {
                    separatorColor = Self.chromeSeparatorColor()
                }
                .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
                    separatorColor = Self.chromeSeparatorColor()
                }
        }
    }

    /// Replicates bonsplit TabBarColors.nsColorSeparator derivation from chrome background.
    private static func chromeSeparatorColor() -> NSColor {
        let chrome = GhosttyBackgroundTheme.currentColor()
        let srgb = chrome.usingColorSpace(.sRGB) ?? chrome
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let isLight = luminance > 0.5
        let amount: CGFloat = isLight ? -0.12 : 0.16
        let alpha: CGFloat = isLight ? 0.26 : 0.36
        return NSColor(
            red: min(1.0, max(0.0, r + amount)),
            green: min(1.0, max(0.0, g + amount)),
            blue: min(1.0, max(0.0, b + amount)),
            alpha: alpha
        )
    }
}

/// Sidebar background that uses the same technique as TitlebarLayerBackground:
/// fully opaque layer color + layer-level opacity. This matches how the terminal's
/// Metal surface composites its background.
private struct SidebarTerminalBackgroundView: NSViewRepresentable {
    let backgroundColor: NSColor
    let opacity: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        view.layer?.opacity = Float(opacity)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        nsView.layer?.opacity = Float(opacity)
    }
}

private struct SidebarBackdrop: View {
    @AppStorage("sidebarMatchTerminalBackground") private var matchTerminalBackground = false
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @Environment(\.colorScheme) private var colorScheme
    @State private var terminalBackgroundColor: NSColor = GhosttyBackgroundTheme.currentColor()

    var body: some View {
        let cornerRadius = CGFloat(max(0, sidebarCornerRadius))

        if matchTerminalBackground {
            // The terminal background is provided by a single CALayer, so
            // the sidebar uses the configured opacity directly.
            let alpha = CGFloat(GhosttyApp.shared.defaultBackgroundOpacity)
            return AnyView(
                SidebarTerminalBackgroundView(
                    backgroundColor: GhosttyApp.shared.defaultBackgroundColor,
                    opacity: alpha
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
                    terminalBackgroundColor = GhosttyBackgroundTheme.currentColor()
                }
            )
        }

        let materialOption = SidebarMaterialOption(rawValue: sidebarMaterial)
        let blendingMode = SidebarBlendModeOption(rawValue: sidebarBlendMode)?.mode ?? .behindWindow
        let state = SidebarStateOption(rawValue: sidebarState)?.state ?? .active
        let resolvedHex: String = {
            if colorScheme == .dark, let dark = sidebarTintHexDark {
                return dark
            } else if colorScheme == .light, let light = sidebarTintHexLight {
                return light
            }
            return sidebarTintHex
        }()
        let tintColor = (NSColor(hex: resolvedHex) ?? NSColor(hex: sidebarTintHex) ?? .black).withAlphaComponent(sidebarTintOpacity)
        let useLiquidGlass = materialOption?.usesLiquidGlass ?? false
        let useWindowLevelGlass = useLiquidGlass && blendingMode == .behindWindow

        return AnyView(
            ZStack {
                if let material = materialOption?.material {
                    // When using liquidGlass + behindWindow, window handles glass + tint
                    // Sidebar is fully transparent
                    if !useWindowLevelGlass {
                        SidebarVisualEffectBackground(
                            material: material,
                            blendingMode: blendingMode,
                            state: state,
                            opacity: sidebarBlurOpacity,
                            tintColor: tintColor,
                            cornerRadius: cornerRadius,
                            preferLiquidGlass: useLiquidGlass
                        )
                        // Tint overlay for NSVisualEffectView fallback
                        if !useLiquidGlass {
                            Color(nsColor: tintColor)
                        }
                    }
                }
                // When material is none or useWindowLevelGlass, render nothing
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
    }
}

enum SidebarMaterialOption: String, CaseIterable, Identifiable {
    case none
    case liquidGlass  // macOS 26+ NSGlassEffectView
    case sidebar
    case hudWindow
    case menu
    case popover
    case underWindowBackground
    case windowBackground
    case contentBackground
    case fullScreenUI
    case sheet
    case headerView
    case toolTip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "settings.material.none", defaultValue: "None")
        case .liquidGlass: return String(localized: "settings.material.liquidGlass", defaultValue: "Liquid Glass (macOS 26+)")
        case .sidebar: return String(localized: "settings.material.sidebar", defaultValue: "Sidebar")
        case .hudWindow: return String(localized: "settings.material.hudWindow", defaultValue: "HUD Window")
        case .menu: return String(localized: "settings.material.menu", defaultValue: "Menu")
        case .popover: return String(localized: "settings.material.popover", defaultValue: "Popover")
        case .underWindowBackground: return String(localized: "settings.material.underWindow", defaultValue: "Under Window")
        case .windowBackground: return String(localized: "settings.material.windowBackground", defaultValue: "Window Background")
        case .contentBackground: return String(localized: "settings.material.contentBackground", defaultValue: "Content Background")
        case .fullScreenUI: return String(localized: "settings.material.fullScreenUI", defaultValue: "Full Screen UI")
        case .sheet: return String(localized: "settings.material.sheet", defaultValue: "Sheet")
        case .headerView: return String(localized: "settings.material.headerView", defaultValue: "Header View")
        case .toolTip: return String(localized: "settings.material.toolTip", defaultValue: "Tool Tip")
        }
    }

    /// Returns true if this option should use NSGlassEffectView (macOS 26+)
    var usesLiquidGlass: Bool {
        self == .liquidGlass
    }

    var material: NSVisualEffectView.Material? {
        switch self {
        case .none: return nil
        case .liquidGlass: return .underWindowBackground  // Fallback material
        case .sidebar: return .sidebar
        case .hudWindow: return .hudWindow
        case .menu: return .menu
        case .popover: return .popover
        case .underWindowBackground: return .underWindowBackground
        case .windowBackground: return .windowBackground
        case .contentBackground: return .contentBackground
        case .fullScreenUI: return .fullScreenUI
        case .sheet: return .sheet
        case .headerView: return .headerView
        case .toolTip: return .toolTip
        }
    }
}

enum SidebarBlendModeOption: String, CaseIterable, Identifiable {
    case behindWindow
    case withinWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .behindWindow: return String(localized: "settings.blendMode.behindWindow", defaultValue: "Behind Window")
        case .withinWindow: return String(localized: "settings.blendMode.withinWindow", defaultValue: "Within Window")
        }
    }

    var mode: NSVisualEffectView.BlendingMode {
        switch self {
        case .behindWindow: return .behindWindow
        case .withinWindow: return .withinWindow
        }
    }
}

enum SidebarStateOption: String, CaseIterable, Identifiable {
    case active
    case inactive
    case followWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return String(localized: "settings.state.active", defaultValue: "Active")
        case .inactive: return String(localized: "settings.state.inactive", defaultValue: "Inactive")
        case .followWindow: return String(localized: "settings.state.followWindow", defaultValue: "Follow Window")
        }
    }

    var state: NSVisualEffectView.State {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .followWindow: return .followsWindowActiveState
        }
    }
}

enum SidebarTintDefaults {
    static let hex = "#000000"
    static let opacity = 0.18
}

enum SidebarPresetOption: String, CaseIterable, Identifiable {
    case nativeSidebar
    case glassBehind
    case softBlur
    case popoverGlass
    case hudGlass
    case underWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeSidebar: return String(localized: "settings.preset.nativeSidebar", defaultValue: "Native Sidebar")
        case .glassBehind: return String(localized: "settings.preset.raycastGray", defaultValue: "Raycast Gray")
        case .softBlur: return String(localized: "settings.preset.softBlur", defaultValue: "Soft Blur")
        case .popoverGlass: return String(localized: "settings.preset.popoverGlass", defaultValue: "Popover Glass")
        case .hudGlass: return String(localized: "settings.preset.hudGlass", defaultValue: "HUD Glass")
        case .underWindow: return String(localized: "settings.preset.underWindow", defaultValue: "Under Window")
        }
    }

    var material: SidebarMaterialOption {
        switch self {
        case .nativeSidebar: return .sidebar
        case .glassBehind: return .sidebar
        case .softBlur: return .sidebar
        case .popoverGlass: return .popover
        case .hudGlass: return .hudWindow
        case .underWindow: return .underWindowBackground
        }
    }

    var blendMode: SidebarBlendModeOption {
        switch self {
        case .nativeSidebar: return .withinWindow
        case .glassBehind: return .behindWindow
        case .softBlur: return .behindWindow
        case .popoverGlass: return .behindWindow
        case .hudGlass: return .withinWindow
        case .underWindow: return .withinWindow
        }
    }

    var state: SidebarStateOption {
        switch self {
        case .nativeSidebar: return .followWindow
        case .glassBehind: return .active
        case .softBlur: return .active
        case .popoverGlass: return .active
        case .hudGlass: return .active
        case .underWindow: return .followWindow
        }
    }

    var tintHex: String {
        switch self {
        case .nativeSidebar: return "#000000"
        case .glassBehind: return "#000000"
        case .softBlur: return "#000000"
        case .popoverGlass: return "#000000"
        case .hudGlass: return "#000000"
        case .underWindow: return "#000000"
        }
    }

    var tintOpacity: Double {
        switch self {
        case .nativeSidebar: return 0.18
        case .glassBehind: return 0.36
        case .softBlur: return 0.28
        case .popoverGlass: return 0.10
        case .hudGlass: return 0.62
        case .underWindow: return 0.14
        }
    }

    var cornerRadius: Double {
        switch self {
        case .nativeSidebar: return 0.0
        case .glassBehind: return 0.0
        case .softBlur: return 0.0
        case .popoverGlass: return 10.0
        case .hudGlass: return 10.0
        case .underWindow: return 6.0
        }
    }

    var blurOpacity: Double {
        switch self {
        case .nativeSidebar: return 1.0
        case .glassBehind: return 0.6
        case .softBlur: return 0.45
        case .popoverGlass: return 0.9
        case .hudGlass: return 0.98
        case .underWindow: return 0.9
        }
    }
}

extension NSColor {
    func hexString(includeAlpha: Bool = false) -> String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redByte = min(255, max(0, Int(red * 255)))
        let greenByte = min(255, max(0, Int(green * 255)))
        let blueByte = min(255, max(0, Int(blue * 255)))
        if includeAlpha {
            let alphaByte = min(255, max(0, Int(alpha * 255)))
            return String(format: "#%02X%02X%02X%02X", redByte, greenByte, blueByte, alphaByte)
        }
        return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
    }
}
