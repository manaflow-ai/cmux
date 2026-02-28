import AppKit
import Bonsplit
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

func sidebarSelectedWorkspaceBackgroundNSColor(for colorScheme: ColorScheme) -> NSColor {
    cmuxAccentNSColor(for: colorScheme)
}

func sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    return NSColor.white.withAlphaComponent(clampedOpacity)
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

/// Applies NSGlassEffectView (macOS 26+) to a window, falling back to NSVisualEffectView
enum WindowGlassEffect {
    private static var glassViewKey: UInt8 = 0
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
        // Note: Removing would require restoring original contentView structure
        // For now, just clear the reference
        objc_setAssociatedObject(window, &glassViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &tintOverlayKey, nil, .OBJC_ASSOCIATION_RETAIN)
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
    static let handleWidth: CGFloat = 6
    static let hitInset: CGFloat = 3

    static var hitWidthPerSide: CGFloat {
        hitInset + (handleWidth / 2)
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
        if let prev = activeDragWebView {
            prev.draggingExited(sender)
            activeDragWebView = nil
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let hasLocalDraggingSource = sender.draggingSource != nil
        let types = sender.draggingPasteboard.types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
        let webView = activeDragWebView
        activeDragWebView = nil
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
        guard shouldCapture else { return false }
        if let webView {
            return webView.performDragOperation(sender)
        }
        guard let terminal else { return false }
        return terminal.performDragOperation(sender)
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
    private func webViewUnderPoint(_ windowPoint: NSPoint) -> WKWebView? {
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
        isHidden = true
        defer { isHidden = false }

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
let commandPaletteOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.commandPalette.overlay.container")

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

    private func isPaletteTextInputFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if let textView = responder as? NSTextView {
            return isPaletteFieldEditor(textView)
        }

        if let textField = responder as? NSTextField {
            return textField.isDescendant(of: containerView)
        }

        return false
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

    private func scheduleFocusIntoPalette(retries: Int = 4) {
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
        if isPaletteTextInputFirstResponder(window.firstResponder) {
            return
        }

        if let textField = firstEditableTextField(in: hostingView),
           window.makeFirstResponder(textField),
           isPaletteTextInputFirstResponder(window.firstResponder) {
            normalizeSelectionAfterProgrammaticFocus()
            return
        }

        if window.makeFirstResponder(containerView) {
            if let textField = firstEditableTextField(in: hostingView),
               window.makeFirstResponder(textField),
               isPaletteTextInputFirstResponder(window.firstResponder) {
                normalizeSelectionAfterProgrammaticFocus()
                return
            }
        }

        guard retries > 0 else { return }
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
            stopFocusLockTimer()
            return
        }

        guard window.isKeyWindow else {
            stopFocusLockTimer()
            if isPaletteResponder(window.firstResponder) {
                _ = window.makeFirstResponder(nil)
            }
            return
        }

        startFocusLockTimer()
        if !isPaletteTextInputFirstResponder(window.firstResponder) {
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

/// Installs a FileDropOverlayView on the window's theme frame for Finder file drag support.
func installFileDropOverlay(on window: NSWindow, tabManager: TabManager) {
    guard objc_getAssociatedObject(window, &fileDropOverlayKey) == nil,
          let contentView = window.contentView,
          let themeFrame = contentView.superview else { return }

    let overlay = FileDropOverlayView(frame: contentView.frame)
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.onDrop = { [weak tabManager] urls in
        MainActor.assumeIsolated {
            guard let tabManager, let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return false }
            return terminal.hostedView.handleDroppedURLs(urls)
        }
    }

    themeFrame.addSubview(overlay, positioned: .above, relativeTo: contentView)
    NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
        overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
    ])

    objc_setAssociatedObject(window, &fileDropOverlayKey, overlay, .OBJC_ASSOCIATION_RETAIN)
}

struct ContentView: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let windowId: UUID
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var sidebarState: SidebarState
    @EnvironmentObject var sidebarSelectionState: SidebarSelectionState
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
    @State private var previousSelectedWorkspaceId: UUID?
    @State private var retiringWorkspaceId: UUID?
    @State private var workspaceHandoffGeneration: UInt64 = 0
    @State private var workspaceHandoffFallbackTask: Task<Void, Never>?
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
    @State private var commandPaletteSelectedResultIndex: Int = 0
    @State private var commandPaletteHoveredResultIndex: Int?
    @State private var commandPaletteScrollTargetIndex: Int?
    @State private var commandPaletteScrollTargetAnchor: UnitPoint?
    @State private var commandPaletteRestoreFocusTarget: CommandPaletteRestoreFocusTarget?
    @State private var commandPaletteUsageHistoryByCommandId: [String: CommandPaletteUsageEntry] = [:]
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
    private var openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
    @FocusState private var isCommandPaletteSearchFocused: Bool
    @FocusState private var isCommandPaletteRenameFocused: Bool

    private enum CommandPaletteMode {
        case commands
        case renameInput(CommandPaletteRenameTarget)
        case renameConfirm(CommandPaletteRenameTarget, proposedName: String)
    }

    private enum CommandPaletteListScope: String {
        case commands
        case switcher
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
                return "Rename Workspace"
            case .tab:
                return "Rename Tab"
            }
        }

        var description: String {
            switch kind {
            case .workspace:
                return "Choose a custom workspace name."
            case .tab:
                return "Choose a custom tab name."
            }
        }

        var placeholder: String {
            switch kind {
            case .workspace:
                return "Workspace name"
            case .tab:
                return "Tab name"
            }
        }
    }

    private enum CommandPaletteRestoreFocusIntent {
        case panel
        case browserAddressBar
    }

    private struct CommandPaletteRestoreFocusTarget {
        let workspaceId: UUID
        let panelId: UUID
        let intent: CommandPaletteRestoreFocusIntent
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
        let keywords: [String]
        let dismissOnRun: Bool
        let action: () -> Void

        var searchableTexts: [String] {
            [title, subtitle] + keywords
        }
    }

    private struct CommandPaletteUsageEntry: Codable {
        var useCount: Int
        var lastUsedAt: TimeInterval
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
    }

    private enum CommandPaletteContextKeys {
        static let hasWorkspace = "workspace.hasSelection"
        static let workspaceName = "workspace.name"
        static let workspaceHasCustomName = "workspace.hasCustomName"
        static let workspaceShouldPin = "workspace.shouldPin"
        static let workspaceHasPullRequests = "workspace.hasPullRequests"
        static let workspaceHasSplits = "workspace.hasSplits"

        static let hasFocusedPanel = "panel.hasFocus"
        static let panelName = "panel.name"
        static let panelIsBrowser = "panel.isBrowser"
        static let panelIsTerminal = "panel.isTerminal"
        static let panelHasCustomName = "panel.hasCustomName"
        static let panelShouldPin = "panel.shouldPin"
        static let panelHasUnread = "panel.hasUnread"

        static let updateHasAvailable = "update.hasAvailable"

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

    private struct CommandPaletteSwitcherWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let selectedWorkspaceId: UUID?
        let windowLabel: String?
    }

    private static let fixedSidebarResizeCursor = NSCursor(
        image: NSCursor.resizeLeftRight.image,
        hotSpot: NSCursor.resizeLeftRight.hotSpot
    )
    private static let commandPaletteUsageDefaultsKey = "commandPalette.commandUsage.v1"
    private static let commandPaletteCommandsPrefix = ">"
    private static let minimumSidebarWidth: CGFloat = 186
    private static let maximumSidebarWidthRatio: CGFloat = 1.0 / 3.0

    private enum SidebarResizerHandle: Hashable {
        case divider
    }

    private var sidebarResizerHitWidthPerSide: CGFloat {
        SidebarResizeInteraction.hitWidthPerSide
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

    private func clampSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = max(
            Self.minimumSidebarWidth,
            min(maxSidebarWidth(availableWidth: availableWidth), sidebarWidth)
        )
        guard abs(nextWidth - sidebarWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            sidebarWidth = nextWidth
        }
    }

    private func normalizedSidebarWidth(_ candidate: CGFloat) -> CGFloat {
        let minWidth = CGFloat(SessionPersistencePolicy.minimumSidebarWidth)
        let maxWidth = max(minWidth, maxSidebarWidth())
        if !candidate.isFinite {
            return CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
        }
        return max(minWidth, min(maxWidth, candidate))
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
        let minX = sidebarWidth - sidebarResizerHitWidthPerSide
        let maxX = sidebarWidth + sidebarResizerHitWidthPerSide
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
                isResizerDragging = false
                sidebarDragStartWidth = nil
                isResizerBandActive = false
                scheduleSidebarResizerCursorRelease(force: true)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isResizerDragging {
                            isResizerDragging = true
                            sidebarDragStartWidth = sidebarWidth
                            #if DEBUG
                            dlog("sidebar.resizeDragStart")
                            #endif
                        }

                        activateSidebarResizerCursor()
                        let startWidth = sidebarDragStartWidth ?? sidebarWidth
                        let nextWidth = max(
                            Self.minimumSidebarWidth,
                            min(maxSidebarWidth(availableWidth: availableWidth), startWidth + value.translation.width)
                        )
                        withTransaction(Transaction(animation: nil)) {
                            sidebarWidth = nextWidth
                        }
                    }
                    .onEnded { _ in
                        if isResizerDragging {
                            isResizerDragging = false
                            sidebarDragStartWidth = nil
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
            let leadingWidth = max(0, dividerX - sidebarResizerHitWidthPerSide)

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leadingWidth)
                    .allowsHitTesting(false)

                sidebarResizerHandleOverlay(
                    .divider,
                    width: sidebarResizerHitWidthPerSide * 2,
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
            selection: $sidebarSelectionState.selection,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        .frame(width: sidebarWidth)
    }

    /// Space at top of content area for the titlebar. This must be at least the actual titlebar
    /// height; otherwise controls like Bonsplit tab dragging can be interpreted as window drags.
    @State private var titlebarPadding: CGFloat = 32

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
                    // Keep the retiring workspace visible during handoff, but never input-active.
                    // Allowing both selected+retiring workspaces to be input-active lets the
                    // old workspace steal first responder (notably with WKWebView), which can
                    // delay handoff completion and make browser returns feel laggy.
                    let isInputActive = isSelectedWorkspace
                    let isVisible = isSelectedWorkspace || isRetiringWorkspace
                    let portalPriority = isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0)
                    WorkspaceContentView(
                        workspace: tab,
                        isWorkspaceVisible: isVisible,
                        isWorkspaceInputActive: isInputActive,
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
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isSelectedWorkspace)
                    .zIndex(isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0))
                }
            }
            .opacity(sidebarSelectionState.selection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelectionState.selection == .tabs)

            NotificationsPage(selection: $sidebarSelectionState.selection)
                .opacity(sidebarSelectionState.selection == .notifications ? 1 : 0)
                .allowsHitTesting(sidebarSelectionState.selection == .notifications)
        }
        .padding(.top, titlebarPadding)
        .overlay(alignment: .top) {
            // Titlebar overlay is only over terminal content, not the sidebar.
            customTitlebar
        }
    }

    private var terminalContentWithSidebarDropOverlay: some View {
        terminalContent
            .overlay {
                SidebarExternalDropOverlay(draggedTabId: sidebarDraggedTabId)
            }
    }

    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue

    // Background glass settings
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = true
    @AppStorage("debugTitlebarLeadingExtra") private var debugTitlebarLeadingExtra: Double = 0

    @State private var titlebarLeadingInset: CGFloat = 12
    private var windowIdentifier: String { "cmux.main.\(windowId.uuidString)" }
    private var fakeTitlebarBackground: Color {
        _ = titlebarThemeGeneration
        let ghosttyBackground = GhosttyApp.shared.defaultBackgroundColor
        let configuredOpacity = CGFloat(max(0, min(1, GhosttyApp.shared.defaultBackgroundOpacity)))
        let minimumChromeOpacity: CGFloat = ghosttyBackground.isLightColor ? 0.90 : 0.84
        let chromeOpacity = max(minimumChromeOpacity, configuredOpacity)
        return Color(nsColor: ghosttyBackground.withAlphaComponent(chromeOpacity))
    }
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
            onNewTab: { tabManager.addTab() }
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
        .background(fakeTitlebarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
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
        if sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue {
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
                    if isFullScreen && sidebarState.isVisible {
                        fullscreenControls
                            .padding(.leading, 10)
                            .padding(.top, 4)
                    }
                }
                .frame(minWidth: 800, minHeight: 600)
                .background(Color.clear)
        )

        view = AnyView(view.onAppear {
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
            updateTitlebarText()

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
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedPanelId = selectedWorkspace.focusedPanelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: focusedPanelId),
                  focusedBrowser.webView === webView else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_first_responder")
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  selectedWorkspace.focusedPanelId == panelId,
                  selectedWorkspace.browserPanel(for: panelId) != nil else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_address_bar")
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

        view = AnyView(view.background(WindowAccessor(dedupeByWindow: false) { window in
            MainActor.assumeIsolated {
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
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = false
            setTitlebarControlsHidden(false, in: window)
            AppDelegate.shared?.fullscreenControlsViewModel = nil
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
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarState.isVisible) { _ in
            updateSidebarResizerBandState()
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

        view = AnyView(view.onDisappear {
            removeSidebarResizerPointerMonitor()
        })

        view = AnyView(view.background(WindowAccessor { [sidebarBlendMode, bgGlassEnabled, bgGlassTintHex, bgGlassTintOpacity] window in
            window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
            window.titlebarAppearsTransparent = true
            // Do not make the entire background draggable; it interferes with drag gestures
            // like sidebar tab reordering in multi-window mode.
            window.isMovableByWindowBackground = false
            // Keep the window immovable by default so titlebar controls (like the folder icon)
            // cannot accidentally initiate native window drags.
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
            if abs(titlebarPadding - nextPadding) > 0.5 {
                DispatchQueue.main.async {
                    titlebarPadding = nextPadding
                }
            }
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1" {
                UpdateLogStore.shared.append("ui test window accessor: id=\(windowIdentifier) visible=\(window.isVisible)")
            }
#endif
            // Background glass: skip on macOS 26+ where NSGlassEffectView can cause blank
            // or incorrectly tinted SwiftUI content. Keep native window rendering there so
            // Ghostty theme colors remain authoritative.
            if sidebarBlendMode == SidebarBlendModeOption.behindWindow.rawValue
                && bgGlassEnabled
                && !WindowGlassEffect.isAvailable {
                window.isOpaque = false
                window.backgroundColor = .clear
                // Configure contentView and all subviews for transparency
                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    contentView.layer?.backgroundColor = NSColor.clear.cgColor
                    contentView.layer?.isOpaque = false
                    // Make SwiftUI hosting view transparent
                    for subview in contentView.subviews {
                        subview.wantsLayer = true
                        subview.layer?.backgroundColor = NSColor.clear.cgColor
                        subview.layer?.isOpaque = false
                    }
                }
                // Apply liquid glass effect to the window with tint from settings
                let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
                WindowGlassEffect.apply(to: window, tintColor: tintColor)
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
            installFileDropOverlay(on: window, tabManager: tabManager)
        }))

        return view
    }

    private func reconcileMountedWorkspaceIds(tabs: [Workspace]? = nil, selectedId: UUID? = nil) {
        let currentTabs = tabs ?? tabManager.tabs
        let orderedTabIds = currentTabs.map { $0.id }
        let effectiveSelectedId = selectedId ?? tabManager.selectedTabId
        let pinnedIds = retiringWorkspaceId.map { Set([ $0 ]) } ?? []
        let isCycleHot = tabManager.isWorkspaceCycleHot
        let shouldKeepHandoffPair = isCycleHot && !pinnedIds.isEmpty
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

    private func addTab() {
        tabManager.addTab()
        sidebarSelectionState.selection = .tabs
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

    private func completeWorkspaceHandoff(reason: String) {
        workspaceHandoffFallbackTask?.cancel()
        workspaceHandoffFallbackTask = nil
        let retiring = retiringWorkspaceId

        // Hide terminal portal views for the retiring workspace BEFORE clearing
        // retiringWorkspaceId. Once cleared, reconcileMountedWorkspaceIds unmounts
        // the workspace — but dismantleNSView intentionally doesn't hide portal views
        // (to avoid blackouts during transient bonsplit dismantles). Hiding here
        // prevents stale portal-hosted terminals from covering browser panes.
        if let retiring, let workspace = tabManager.tabs.first(where: { $0.id == retiring }) {
            workspace.hideAllTerminalPortalViews()
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

            ZStack(alignment: .top) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissCommandPalette()
                    }

                VStack(spacing: 0) {
                    switch commandPaletteMode {
                    case .commands:
                        commandPaletteCommandListView
                    case .renameInput(let target):
                        commandPaletteRenameInputView(target: target)
                    case let .renameConfirm(target, proposedName):
                        commandPaletteRenameConfirmView(target: target, proposedName: proposedName)
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
        let visibleResults = Array(commandPaletteResults)
        let selectedIndex = commandPaletteSelectedIndex(resultCount: visibleResults.count)
        let commandPaletteListMaxHeight: CGFloat = 450
        let commandPaletteRowHeight: CGFloat = 24
        let commandPaletteEmptyStateHeight: CGFloat = 44
        let commandPaletteListContentHeight = visibleResults.isEmpty
            ? commandPaletteEmptyStateHeight
            : CGFloat(visibleResults.count) * commandPaletteRowHeight
        let commandPaletteListHeight = min(commandPaletteListMaxHeight, commandPaletteListContentHeight)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(commandPaletteSearchPlaceholder, text: $commandPaletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .regular))
                    .tint(Color(nsColor: sidebarActiveForegroundNSColor(opacity: 1.0)))
                    .focused($isCommandPaletteSearchFocused)
                    .onSubmit {
                        runSelectedCommandPaletteResult(visibleResults: visibleResults)
                    }
                    .backport.onKeyPress(.downArrow) { _ in
                        moveCommandPaletteSelection(by: 1)
                        return .handled
                    }
                    .backport.onKeyPress(.upArrow) { _ in
                        moveCommandPaletteSelection(by: -1)
                        return .handled
                    }
                    .backport.onKeyPress("n") { modifiers in
                        handleCommandPaletteControlNavigationKey(modifiers: modifiers, delta: 1)
                    }
                    .backport.onKeyPress("p") { modifiers in
                        handleCommandPaletteControlNavigationKey(modifiers: modifiers, delta: -1)
                    }
                    .backport.onKeyPress("j") { modifiers in
                        handleCommandPaletteControlNavigationKey(modifiers: modifiers, delta: 1)
                    }
                    .backport.onKeyPress("k") { modifiers in
                        handleCommandPaletteControlNavigationKey(modifiers: modifiers, delta: -1)
                    }

            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if visibleResults.isEmpty {
                        Text(commandPaletteEmptyStateText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
                            let isSelected = index == selectedIndex
                            let isHovered = commandPaletteHoveredResultIndex == index
                            let rowBackground: Color = isSelected
                                ? cmuxAccentColor().opacity(0.12)
                                : (isHovered ? Color.primary.opacity(0.08) : .clear)

                            Button {
                                runCommandPaletteCommand(result.command)
                            } label: {
                                HStack(spacing: 8) {
                                    commandPaletteHighlightedTitleText(
                                        result.command.title,
                                        matchedIndices: result.titleMatchIndices
                                    )
                                        .font(.system(size: 13, weight: .regular))
                                        .lineLimit(1)
                                    Spacer()

                                    if let trailingLabel = commandPaletteTrailingLabel(for: result.command) {
                                        switch trailingLabel.style {
                                        case .shortcut:
                                            Text(trailingLabel.text)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        case .kind:
                                            Text(trailingLabel.text)
                                                .font(.system(size: 11, weight: .regular))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(rowBackground)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
                // Force a fresh row tree per query so rendered labels/actions stay in lockstep.
                .id(commandPaletteQuery)
            }
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
            updateCommandPaletteScrollTarget(resultCount: visibleResults.count, animated: false)
            resetCommandPaletteSearchFocus()
        }
        .onChange(of: commandPaletteQuery) { _ in
            commandPaletteSelectedResultIndex = 0
            commandPaletteHoveredResultIndex = nil
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: visibleResults.count) { _ in
            commandPaletteSelectedResultIndex = commandPaletteSelectedIndex(resultCount: visibleResults.count)
            updateCommandPaletteScrollTarget(resultCount: visibleResults.count, animated: false)
            if let hoveredIndex = commandPaletteHoveredResultIndex, hoveredIndex >= visibleResults.count {
                commandPaletteHoveredResultIndex = nil
            }
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteSelectedResultIndex) { _ in
            syncCommandPaletteDebugStateForObservedWindow()
        }
    }

    private func commandPaletteRenameInputView(target: CommandPaletteRenameTarget) -> some View {
        VStack(spacing: 0) {
            TextField(target.placeholder, text: $commandPaletteRenameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .tint(Color(nsColor: sidebarActiveForegroundNSColor(opacity: 1.0)))
                .focused($isCommandPaletteRenameFocused)
                .backport.onKeyPress(.delete) { modifiers in
                    handleCommandPaletteRenameDeleteBackward(modifiers: modifiers)
                }
                .onSubmit {
                    continueRenameFlow(target: target)
                }
                .onTapGesture {
                    handleCommandPaletteRenameInputInteraction()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text("Enter a \(renameTargetNoun(target)) name. Press Enter to rename, Escape to cancel.")
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
        let nextName = trimmedName.isEmpty ? "(clear custom name)" : trimmedName

        return VStack(spacing: 0) {
            Text(nextName)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text("Press Enter to apply this \(renameTargetNoun(target)) name, or Escape to cancel.")
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

    private func renameTargetNoun(_ target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return "workspace"
        case .tab:
            return "tab"
        }
    }

    private var commandPaletteListScope: CommandPaletteListScope {
        if commandPaletteQuery.hasPrefix(Self.commandPaletteCommandsPrefix) {
            return .commands
        }
        return .switcher
    }

    private var commandPaletteSearchPlaceholder: String {
        switch commandPaletteListScope {
        case .commands:
            return "Type a command"
        case .switcher:
            return "Search workspaces and tabs"
        }
    }

    private var commandPaletteEmptyStateText: String {
        switch commandPaletteListScope {
        case .commands:
            return "No commands match your search."
        case .switcher:
            return "No workspaces or tabs match your search."
        }
    }

    private var commandPaletteQueryForMatching: String {
        switch commandPaletteListScope {
        case .commands:
            let suffix = String(commandPaletteQuery.dropFirst(Self.commandPaletteCommandsPrefix.count))
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        case .switcher:
            return commandPaletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var commandPaletteEntries: [CommandPaletteCommand] {
        switch commandPaletteListScope {
        case .commands:
            return commandPaletteCommands()
        case .switcher:
            return commandPaletteSwitcherEntries()
        }
    }

    private var commandPaletteResults: [CommandPaletteSearchResult] {
        let entries = commandPaletteEntries
        let query = commandPaletteQueryForMatching
        let queryIsEmpty = query.isEmpty

        let results: [CommandPaletteSearchResult] = queryIsEmpty
            ? entries.map { entry in
                CommandPaletteSearchResult(
                    command: entry,
                    score: commandPaletteHistoryBoost(for: entry.id, queryIsEmpty: true),
                    titleMatchIndices: []
                )
            }
            : entries.compactMap { entry in
                guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(query: query, candidates: entry.searchableTexts) else {
                    return nil
                }
                return CommandPaletteSearchResult(
                    command: entry,
                    score: fuzzyScore + commandPaletteHistoryBoost(for: entry.id, queryIsEmpty: false),
                    titleMatchIndices: CommandPaletteFuzzyMatcher.matchCharacterIndices(
                        query: query,
                        candidate: entry.title
                    )
                )
            }

        return results
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.command.rank != rhs.command.rank { return lhs.command.rank < rhs.command.rank }
                return lhs.command.title.localizedCaseInsensitiveCompare(rhs.command.title) == .orderedAscending
            }
    }

    private func commandPaletteHighlightedTitleText(_ title: String, matchedIndices: Set<Int>) -> Text {
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

    private func commandPaletteTrailingLabel(for command: CommandPaletteCommand) -> CommandPaletteTrailingLabel? {
        if let shortcutHint = command.shortcutHint {
            return CommandPaletteTrailingLabel(text: shortcutHint, style: .shortcut)
        }

        guard commandPaletteListScope == .switcher else { return nil }
        if command.id.hasPrefix("switcher.workspace.") {
            return CommandPaletteTrailingLabel(text: "Workspace", style: .kind)
        }
        if command.id.hasPrefix("switcher.surface.") {
            return CommandPaletteTrailingLabel(text: "Surface", style: .kind)
        }
        return nil
    }

    private func commandPaletteSwitcherEntries() -> [CommandPaletteCommand] {
        let windowContexts = commandPaletteSwitcherWindowContexts()
        guard !windowContexts.isEmpty else { return [] }

        var entries: [CommandPaletteCommand] = []
        let estimatedCount = windowContexts.reduce(0) { partial, context in
            partial + max(1, context.tabManager.tabs.count) * 4
        }
        entries.reserveCapacity(estimatedCount)
        var nextRank = 0

        for context in windowContexts {
            var workspaces = context.tabManager.tabs
            guard !workspaces.isEmpty else { continue }

            let selectedWorkspaceId = context.selectedWorkspaceId ?? context.tabManager.selectedTabId
            if let selectedWorkspaceId,
               let selectedIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspaceId }) {
                let selectedWorkspace = workspaces.remove(at: selectedIndex)
                workspaces.insert(selectedWorkspace, at: 0)
            }

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
                        subtitle: commandPaletteSwitcherSubtitle(base: "Workspace", windowLabel: context.windowLabel),
                        shortcutHint: nil,
                        keywords: workspaceKeywords,
                        dismissOnRun: true,
                        action: {
                            focusCommandPaletteSwitcherTarget(
                                windowId: windowId,
                                tabManager: windowTabManager,
                                workspaceId: workspaceId,
                                panelId: nil
                            )
                        }
                    )
                )
                nextRank += 1

                var orderedPanelIds = workspace.sidebarOrderedPanelIds()
                if let focusedPanelId = workspace.focusedPanelId,
                   let focusedIndex = orderedPanelIds.firstIndex(of: focusedPanelId) {
                    orderedPanelIds.remove(at: focusedIndex)
                    orderedPanelIds.insert(focusedPanelId, at: 0)
                }

                for panelId in orderedPanelIds {
                    guard let panel = workspace.panels[panelId] else { continue }
                    let panelTitle = panelDisplayName(workspace: workspace, panelId: panelId, fallback: panel.displayTitle)
                    let typeLabel: String = (panel.panelType == .browser) ? "Browser" : "Terminal"
                    let panelKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
                        baseKeywords: [
                            "tab",
                            "surface",
                            "panel",
                            "switch",
                            "go",
                            workspaceName,
                            panelTitle,
                            typeLabel.lowercased()
                        ] + windowKeywords,
                        metadata: commandPalettePanelSearchMetadata(in: workspace, panelId: panelId)
                    )
                    entries.append(
                        CommandPaletteCommand(
                            id: "switcher.surface.\(workspace.id.uuidString.lowercased()).\(panelId.uuidString.lowercased())",
                            rank: nextRank,
                            title: panelTitle,
                            subtitle: commandPaletteSwitcherSubtitle(
                                base: "\(typeLabel) • \(workspaceName)",
                                windowLabel: context.windowLabel
                            ),
                            shortcutHint: nil,
                            keywords: panelKeywords,
                            dismissOnRun: true,
                            action: {
                                focusCommandPaletteSwitcherTarget(
                                    windowId: windowId,
                                    tabManager: windowTabManager,
                                    workspaceId: workspaceId,
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
                windowLabelById[summary.windowId] = "Window \(index + 1)"
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

    private func commandPaletteSwitcherSubtitle(base: String, windowLabel: String?) -> String {
        guard let windowLabel else { return base }
        return "\(base) • \(windowLabel)"
    }

    private func commandPaletteWindowKeywords(windowLabel: String?) -> [String] {
        guard let windowLabel else { return [] }
        return ["window", windowLabel.lowercased()]
    }

    private func focusCommandPaletteSwitcherTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID?
    ) {
        // Switcher commands dismiss the palette after action dispatch.
        // Defer focus mutation one turn so browser omnibar autofocus can run
        // without being blocked by the palette-visibility guard.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            if let panelId {
                tabManager.focusTab(workspaceId, surfaceId: panelId, suppressFlash: true)
            } else {
                tabManager.focusTab(workspaceId, suppressFlash: true)
            }
        }
    }

    private func commandPaletteWorkspaceSearchMetadata(for workspace: Workspace) -> CommandPaletteSwitcherSearchMetadata {
        // Keep workspace rows coarse so surface rows win for directory/branch-specific queries.
        let directories = [workspace.currentDirectory]
        let branches = [workspace.gitBranch?.branch].compactMap { $0 }
        let ports = workspace.listeningPorts
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
    }

    private func commandPalettePanelSearchMetadata(in workspace: Workspace, panelId: UUID) -> CommandPaletteSwitcherSearchMetadata {
        var directories: [String] = []
        if let directory = workspace.panelDirectories[panelId] {
            directories.append(directory)
        } else if workspace.focusedPanelId == panelId {
            directories.append(workspace.currentDirectory)
        }

        var branches: [String] = []
        if let branch = workspace.panelGitBranches[panelId]?.branch {
            branches.append(branch)
        } else if workspace.focusedPanelId == panelId, let branch = workspace.gitBranch?.branch {
            branches.append(branch)
        }

        var ports = workspace.surfaceListeningPorts[panelId] ?? []
        if ports.isEmpty, workspace.panels.count == 1 {
            ports = workspace.listeningPorts
        }

        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
    }

    private func commandPaletteCommands() -> [CommandPaletteCommand] {
        let context = commandPaletteContextSnapshot()
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
        case "palette.browserSplitRight", "palette.terminalSplitBrowserRight":
            return .splitBrowserRight
        case "palette.browserSplitDown", "palette.terminalSplitBrowserDown":
            return .splitBrowserDown
        case "palette.terminalSplitRight":
            return .splitRight
        case "palette.terminalSplitDown":
            return .splitDown
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
            return "⌘⇧G"
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

    private func commandPaletteContextSnapshot() -> CommandPaletteContextSnapshot {
        var snapshot = CommandPaletteContextSnapshot()

        if let workspace = tabManager.selectedWorkspace {
            snapshot.setBool(CommandPaletteContextKeys.hasWorkspace, true)
            snapshot.setString(CommandPaletteContextKeys.workspaceName, workspaceDisplayName(workspace))
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomName, workspace.customTitle != nil)
            snapshot.setBool(CommandPaletteContextKeys.workspaceShouldPin, !workspace.isPinned)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasPullRequests,
                !workspace.sidebarPullRequestsInDisplayOrder().isEmpty
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasSplits,
                workspace.bonsplitController.allPaneIds.count > 1
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
                let availableTargets = TerminalDirectoryOpenTarget.cachedLiveAvailableTargets
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
            let name = context.string(CommandPaletteContextKeys.workspaceName) ?? "Workspace"
            return "Workspace • \(name)"
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? "Tab"
            return "Tab • \(name)"
        }

        func browserPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? "Tab"
            return "Browser • \(name)"
        }

        func terminalPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? "Tab"
            return "Terminal • \(name)"
        }

        var contributions: [CommandPaletteCommandContribution] = []

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                title: constant("New Workspace"),
                subtitle: constant("Workspace"),
                keywords: ["create", "new", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWindow",
                title: constant("New Window"),
                subtitle: constant("Window"),
                keywords: ["create", "new", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.installCLI",
                title: constant("Shell Command: Install 'cmux' in PATH"),
                subtitle: constant("CLI"),
                keywords: ["install", "cli", "path", "shell", "command", "symlink"],
                when: { _ in !(AppDelegate.shared?.isCmuxCLIInstalledInPATH() ?? false) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.uninstallCLI",
                title: constant("Shell Command: Uninstall 'cmux' from PATH"),
                subtitle: constant("CLI"),
                keywords: ["uninstall", "remove", "cli", "path", "shell", "command", "symlink"],
                when: { _ in AppDelegate.shared?.isCmuxCLIInstalledInPATH() ?? false }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolder",
                title: constant("Open Folder…"),
                subtitle: constant("Workspace"),
                keywords: ["open", "folder", "repository", "project", "directory"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalTab",
                title: constant("New Tab (Terminal)"),
                subtitle: constant("Tab"),
                shortcutHint: "⌘T",
                keywords: ["new", "terminal", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserTab",
                title: constant("New Tab (Browser)"),
                subtitle: constant("Tab"),
                shortcutHint: "⌘⇧L",
                keywords: ["new", "browser", "tab", "web"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeTab",
                title: constant("Close Tab"),
                subtitle: constant("Tab"),
                shortcutHint: "⌘W",
                keywords: ["close", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspace",
                title: constant("Close Workspace"),
                subtitle: constant("Workspace"),
                shortcutHint: "⌘⇧W",
                keywords: ["close", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWindow",
                title: constant("Close Window"),
                subtitle: constant("Window"),
                keywords: ["close", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleFullScreen",
                title: constant("Toggle Full Screen"),
                subtitle: constant("Window"),
                keywords: ["fullscreen", "full", "screen", "window", "toggle"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenClosedBrowserTab",
                title: constant("Reopen Closed Browser Tab"),
                subtitle: constant("Browser"),
                shortcutHint: "⌘⇧T",
                keywords: ["reopen", "closed", "browser"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSidebar",
                title: constant("Toggle Sidebar"),
                subtitle: constant("Layout"),
                keywords: ["toggle", "sidebar", "layout"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant("Flash Focused Panel"),
                subtitle: constant("View"),
                keywords: ["flash", "highlight", "focus", "panel"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.showNotifications",
                title: constant("Show Notifications"),
                subtitle: constant("Notifications"),
                keywords: ["notifications", "inbox"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpUnread",
                title: constant("Jump to Latest Unread"),
                subtitle: constant("Notifications"),
                keywords: ["jump", "unread", "notification"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openSettings",
                title: constant("Open Settings"),
                subtitle: constant("Global"),
                shortcutHint: "⌘,",
                keywords: ["settings", "preferences"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.checkForUpdates",
                title: constant("Check for Updates"),
                subtitle: constant("Global"),
                keywords: ["update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.applyUpdateIfAvailable",
                title: constant("Apply Update (If Available)"),
                subtitle: constant("Global"),
                keywords: ["apply", "install", "update", "available"],
                when: { $0.bool(CommandPaletteContextKeys.updateHasAvailable) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.attemptUpdate",
                title: constant("Attempt Update"),
                subtitle: constant("Global"),
                keywords: ["attempt", "check", "update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.restartSocketListener",
                title: constant("Restart CLI Listener"),
                subtitle: constant("Global"),
                keywords: ["restart", "socket", "listener", "cli", "cmux", "control"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameWorkspace",
                title: constant("Rename Workspace…"),
                subtitle: workspaceSubtitle,
                keywords: ["rename", "workspace", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceName",
                title: constant("Clear Workspace Name"),
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
                commandId: "palette.toggleWorkspacePin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.workspaceShouldPin) ? "Pin Workspace" : "Unpin Workspace"
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextWorkspace",
                title: constant("Next Workspace"),
                subtitle: constant("Workspace Navigation"),
                keywords: ["next", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousWorkspace",
                title: constant("Previous Workspace"),
                subtitle: constant("Workspace Navigation"),
                keywords: ["previous", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameTab",
                title: constant("Rename Tab…"),
                subtitle: panelSubtitle,
                keywords: ["rename", "tab", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearTabName",
                title: constant("Clear Tab Name"),
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
                    context.bool(CommandPaletteContextKeys.panelShouldPin) ? "Pin Tab" : "Unpin Tab"
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
                    context.bool(CommandPaletteContextKeys.panelHasUnread) ? "Mark Tab as Read" : "Mark Tab as Unread"
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextTabInPane",
                title: constant("Next Tab in Pane"),
                subtitle: constant("Tab Navigation"),
                keywords: ["next", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousTabInPane",
                title: constant("Previous Tab in Pane"),
                subtitle: constant("Tab Navigation"),
                keywords: ["previous", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openWorkspacePullRequests",
                title: constant("Open All Workspace PR Links"),
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
                title: constant("Back"),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘[",
                keywords: ["browser", "back", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserForward",
                title: constant("Forward"),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘]",
                keywords: ["browser", "forward", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReload",
                title: constant("Reload Page"),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘R",
                keywords: ["browser", "reload", "refresh"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserOpenDefault",
                title: constant("Open Current Page in Default Browser"),
                subtitle: browserPanelSubtitle,
                keywords: ["open", "default", "external", "browser"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserFocusAddressBar",
                title: constant("Focus Address Bar"),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘L",
                keywords: ["browser", "address", "omnibar", "url"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserToggleDevTools",
                title: constant("Toggle Developer Tools"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "devtools", "inspector"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserConsole",
                title: constant("Show JavaScript Console"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "console", "javascript"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomIn",
                title: constant("Zoom In"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "in"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomOut",
                title: constant("Zoom Out"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "out"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomReset",
                title: constant("Actual Size"),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "reset", "actual size"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserClearHistory",
                title: constant("Clear Browser History"),
                subtitle: constant("Browser"),
                keywords: ["browser", "history", "clear"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitRight",
                title: constant("Split Browser Right"),
                subtitle: constant("Browser Layout"),
                keywords: ["browser", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitDown",
                title: constant("Split Browser Down"),
                subtitle: constant("Browser Layout"),
                keywords: ["browser", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserDuplicateRight",
                title: constant("Duplicate Browser to the Right"),
                subtitle: constant("Browser Layout"),
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
                            && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(target))
                    }
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFind",
                title: constant("Find…"),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘F",
                keywords: ["terminal", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindNext",
                title: constant("Find Next"),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘G",
                keywords: ["terminal", "find", "next", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindPrevious",
                title: constant("Find Previous"),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘⇧G",
                keywords: ["terminal", "find", "previous", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalHideFind",
                title: constant("Hide Find Bar"),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘⇧F",
                keywords: ["terminal", "hide", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalUseSelectionForFind",
                title: constant("Use Selection for Find"),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "selection", "find"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitRight",
                title: constant("Split Right"),
                subtitle: constant("Terminal Layout"),
                keywords: ["terminal", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitDown",
                title: constant("Split Down"),
                subtitle: constant("Terminal Layout"),
                keywords: ["terminal", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserRight",
                title: constant("Split Browser Right"),
                subtitle: constant("Terminal Layout"),
                keywords: ["terminal", "split", "browser", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserDown",
                title: constant("Split Browser Down"),
                subtitle: constant("Terminal Layout"),
                keywords: ["terminal", "split", "browser", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSplitZoom",
                title: constant("Toggle Pane Zoom"),
                subtitle: constant("Terminal Layout"),
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
                title: constant("Equalize Splits"),
                subtitle: workspaceSubtitle,
                keywords: ["split", "equalize", "balance", "divider", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            )
        )

        return contributions
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
                panel.title = "Open Folder"
                panel.prompt = "Open"
                if panel.runModal() == .OK, let url = panel.url {
                    tabManager.addWorkspace(workingDirectory: url.path)
                }
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
            window.performClose(nil)
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
        registry.register(commandId: "palette.clearWorkspaceName") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomTitle(tabId: workspace.id)
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
    }

    private var focusedPanelContext: (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom
        }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Workspace" : title
    }

    private func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "Tab" : trimmedFallback
    }

    private func commandPaletteSelectedIndex(resultCount: Int) -> Int {
        guard resultCount > 0 else { return 0 }
        return min(max(commandPaletteSelectedResultIndex, 0), resultCount - 1)
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

    private func moveCommandPaletteSelection(by delta: Int) {
        let count = commandPaletteResults.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        let current = commandPaletteSelectedIndex(resultCount: count)
        commandPaletteSelectedResultIndex = min(max(current + delta, 0), count - 1)
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func handleCommandPaletteControlNavigationKey(
        modifiers: EventModifiers,
        delta: Int
    ) -> BackportKeyPressResult {
        guard modifiers.contains(.control),
              !modifiers.contains(.command),
              !modifiers.contains(.shift),
              !modifiers.contains(.option) else {
            return .ignored
        }
        moveCommandPaletteSelection(by: delta)
        return .handled
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

    private func runSelectedCommandPaletteResult(visibleResults: [CommandPaletteSearchResult]? = nil) {
        let visibleResults = visibleResults ?? Array(commandPaletteResults)
        guard !visibleResults.isEmpty else {
            NSSound.beep()
            return
        }
        let index = commandPaletteSelectedIndex(resultCount: visibleResults.count)
        runCommandPaletteCommand(visibleResults[index].command)
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
        toggleCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
    }

    private func openCommandPaletteSwitcher() {
        toggleCommandPalette(initialQuery: "")
    }

    private func toggleCommandPalette(initialQuery: String) {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            presentCommandPalette(initialQuery: initialQuery)
        }
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
        focusedPanelId: UUID
    ) -> Bool {
        focusedPanelIsBrowser && focusedBrowserAddressBarPanelId == focusedPanelId
    }

    private func syncCommandPaletteDebugStateForObservedWindow() {
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        AppDelegate.shared?.setCommandPaletteVisible(isCommandPalettePresented, for: window)
        let visibleResultCount = commandPaletteResults.count
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
        }

        let rows = Array(commandPaletteResults.prefix(20)).map { result in
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
            let shouldRestoreBrowserAddressBar = Self.shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
                focusedPanelIsBrowser: panelContext.panel.panelType == .browser,
                focusedBrowserAddressBarPanelId: AppDelegate.shared?.focusedBrowserAddressBarPanelId(),
                focusedPanelId: panelContext.panelId
            )
            commandPaletteRestoreFocusTarget = CommandPaletteRestoreFocusTarget(
                workspaceId: panelContext.workspace.id,
                panelId: panelContext.panelId,
                intent: shouldRestoreBrowserAddressBar ? .browserAddressBar : .panel
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
        commandPaletteSelectedResultIndex = 0
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        resetCommandPaletteSearchFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func dismissCommandPalette(restoreFocus: Bool = true) {
        let focusTarget = commandPaletteRestoreFocusTarget
        isCommandPalettePresented = false
        commandPaletteMode = .commands
        commandPaletteQuery = ""
        commandPaletteRenameDraft = ""
        commandPaletteSelectedResultIndex = 0
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        isCommandPaletteSearchFocused = false
        isCommandPaletteRenameFocused = false
        commandPaletteRestoreFocusTarget = nil
        if let window = observedWindow {
            _ = window.makeFirstResponder(nil)
        }
        syncCommandPaletteDebugStateForObservedWindow()

        guard restoreFocus, let focusTarget else { return }
        restoreCommandPaletteFocus(target: focusTarget, attemptsRemaining: 6)
    }

    private func restoreCommandPaletteFocus(
        target: CommandPaletteRestoreFocusTarget,
        attemptsRemaining: Int
    ) {
        guard !isCommandPalettePresented else { return }
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else { return }

        if let window = observedWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        tabManager.focusTab(target.workspaceId, surfaceId: target.panelId, suppressFlash: true)

        if let context = focusedPanelContext,
           context.workspace.id == target.workspaceId,
           context.panelId == target.panelId {
            restoreCommandPaletteInputFocusIfNeeded(target: target, attemptsRemaining: 6)
            return
        }

        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard !isCommandPalettePresented else { return }
            if let context = focusedPanelContext,
               context.workspace.id == target.workspaceId,
               context.panelId == target.panelId {
                restoreCommandPaletteInputFocusIfNeeded(target: target, attemptsRemaining: 6)
                return
            }
            restoreCommandPaletteFocus(target: target, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func restoreCommandPaletteInputFocusIfNeeded(
        target: CommandPaletteRestoreFocusTarget,
        attemptsRemaining: Int
    ) {
        guard !isCommandPalettePresented else { return }
        guard target.intent == .browserAddressBar else { return }
        guard attemptsRemaining > 0 else { return }
        guard let appDelegate = AppDelegate.shared else { return }

        if appDelegate.requestBrowserAddressBarFocus(panelId: target.panelId) {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            restoreCommandPaletteInputFocusIfNeeded(
                target: target,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func resetCommandPaletteSearchFocus() {
        applyCommandPaletteInputFocusPolicy(.search)
    }

    private func resetCommandPaletteRenameFocus() {
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
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

    private func applyCommandPaletteTextSelection(
        _ behavior: CommandPaletteTextSelectionBehavior,
        attemptsRemaining: Int = 20
    ) {
        guard isCommandPalettePresented else { return }
        switch behavior {
        case .selectAll:
            guard case .renameInput = commandPaletteMode else { return }
        case .caretAtEnd:
            switch commandPaletteMode {
            case .commands, .renameInput:
                break
            case .renameConfirm:
                return
            }
        }
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            let length = (editor.string as NSString).length
            switch behavior {
            case .selectAll:
                editor.setSelectedRange(NSRange(location: 0, length: length))
            case .caretAtEnd:
                editor.setSelectedRange(NSRange(location: length, length: 0))
            }
            return
        }

        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            applyCommandPaletteTextSelection(behavior, attemptsRemaining: attemptsRemaining - 1)
        }
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

    private func commandPaletteHistoryBoost(for commandId: String, queryIsEmpty: Bool) -> Int {
        guard let entry = commandPaletteUsageHistoryByCommandId[commandId] else { return 0 }

        let now = Date().timeIntervalSince1970
        let ageDays = max(0, now - entry.lastUsedAt) / 86_400
        let recencyBoost = max(0, 320 - Int(ageDays * 20))
        let countBoost = min(180, entry.useCount * 12)
        let totalBoost = recencyBoost + countBoost

        return queryIsEmpty ? totalBoost : max(0, totalBoost / 3)
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
        commandPaletteMode = .renameInput(target)
        resetCommandPaletteRenameFocus()
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
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
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

struct CommandPaletteSwitcherSearchMetadata {
    let directories: [String]
    let branches: [String]
    let ports: [Int]

    init(
        directories: [String] = [],
        branches: [String] = [],
        ports: [Int] = []
    ) {
        self.directories = directories
        self.branches = branches
        self.ports = ports
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

        return contextKeywords + directoryTokens + branchTokens + portTokens
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

    static func score(query: String, candidate: String) -> Int? {
        score(query: query, candidates: [candidate])
    }

    static func score(query: String, candidates: [String]) -> Int? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return 0 }
        let tokens = normalizedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return 0 }

        let normalizedCandidates = candidates
            .map(normalize)
            .filter { !$0.isEmpty }
        guard !normalizedCandidates.isEmpty else { return nil }

        var totalScore = 0
        for token in tokens {
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
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let tokens = normalizedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        let loweredCandidate = normalize(candidate)
        guard !loweredCandidate.isEmpty else { return [] }

        let candidateChars = Array(loweredCandidate)
        var matched: Set<Int> = []

        for token in tokens {
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

    private static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
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
        guard length > 0 else { return false }
        guard tokenStart + length <= tokenChars.count else { return false }
        guard candidateStart + length <= candidateChars.count else { return false }

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

struct VerticalTabsSidebar: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @StateObject private var commandKeyMonitor = SidebarCommandKeyMonitor()
    @StateObject private var dragAutoScrollController = SidebarDragAutoScrollController()
    @StateObject private var dragFailsafeMonitor = SidebarDragFailsafeMonitor()
    @State private var draggedTabId: UUID?
    @State private var dropIndicator: SidebarDropIndicator?

    /// Space at top of sidebar for traffic light buttons
    private let trafficLightPadding: CGFloat = 28
    private let tabRowSpacing: CGFloat = 2

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Space for traffic lights / fullscreen controls
                        Spacer()
                            .frame(height: trafficLightPadding)

                        LazyVStack(spacing: tabRowSpacing) {
                            ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                                TabItemView(
                                    tab: tab,
                                    index: index,
                                    rowSpacing: tabRowSpacing,
                                    selection: $selection,
                                    selectedTabIds: $selectedTabIds,
                                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                                    showsCommandShortcutHints: commandKeyMonitor.isCommandPressed,
                                    dragAutoScrollController: dragAutoScrollController,
                                    draggedTabId: $draggedTabId,
                                    dropIndicator: $dropIndicator
                                )
                            }
                        }
                        .padding(.vertical, 8)

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
                }
                .background(Color.clear)
                .modifier(ClearScrollBackground())
            }
#if DEBUG
            SidebarDevFooter(updateViewModel: updateViewModel)
                .frame(maxWidth: .infinity, alignment: .leading)
#else
            UpdatePill(model: updateViewModel)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
#endif
        }
        .accessibilityIdentifier("Sidebar")
        .ignoresSafeArea()
        .background(SidebarBackdrop().ignoresSafeArea())
        .background(
            WindowAccessor { window in
                commandKeyMonitor.setHostWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            commandKeyMonitor.start()
            draggedTabId = nil
            dropIndicator = nil
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: nil,
                reason: "sidebar_appear"
            )
        }
        .onDisappear {
            commandKeyMonitor.stop()
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
        .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.requestClear)) { notification in
            guard draggedTabId != nil else { return }
            let reason = SidebarDragLifecycleNotification.reason(from: notification)
#if DEBUG
            dlog("sidebar.dragClear tab=\(debugShortSidebarTabId(draggedTabId)) reason=\(reason)")
#endif
            draggedTabId = nil
        }
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

enum SidebarCommandHintPolicy {
    static let intentionalHoldDelay: TimeInterval = 0.30

    static func shouldShowHints(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command]
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
        keyWindowNumber: Int?
    ) -> Bool {
        shouldShowHints(for: modifierFlags) &&
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

    static let defaultSidebarHintX = 0.0
    static let defaultSidebarHintY = 0.0
    static let defaultTitlebarHintX = 4.0
    static let defaultTitlebarHintY = 0.0
    static let defaultPaneHintX = 0.0
    static let defaultPaneHintY = 0.0
    static let defaultAlwaysShowHints = false

    static let offsetRange: ClosedRange<Double> = -20...20

    static func clamped(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
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
    static let pollInterval: TimeInterval = 0.05
    static let clearDelay: TimeInterval = 0.15

    static func shouldRequestClear(isDragActive: Bool, isLeftMouseButtonDown: Bool) -> Bool {
        isDragActive && !isLeftMouseButtonDown
    }
}

@MainActor
private final class SidebarDragFailsafeMonitor: ObservableObject {
    private static let escapeKeyCode: UInt16 = 53
    private var timer: Timer?
    private var pendingClearWorkItem: DispatchWorkItem?
    private var appResignObserver: NSObjectProtocol?
    private var keyDownMonitor: Any?
    private var onRequestClear: ((String) -> Void)?

    func start(onRequestClear: @escaping (String) -> Void) {
        self.onRequestClear = onRequestClear
        if timer == nil {
            let timer = Timer(timeInterval: SidebarDragFailsafePolicy.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
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
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
        onRequestClear = nil
    }

    private func tick() {
        let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        guard SidebarDragFailsafePolicy.shouldRequestClear(
            isDragActive: true, // Monitor only runs while drag is active.
            isLeftMouseButtonDown: isLeftMouseButtonDown
        ) else { return }
        requestClearSoon(reason: "mouse_up_failsafe")
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
private final class SidebarCommandKeyMonitor: ObservableObject {
    @Published private(set) var isCommandPressed = false

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
        SidebarCommandHintPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard SidebarCommandHintPolicy.shouldShowHints(
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
        guard !isCommandPressed else { return }
        guard pendingShowWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            guard SidebarCommandHintPolicy.shouldShowHints(
                for: NSEvent.modifierFlags,
                hostWindowNumber: self.hostWindow?.windowNumber,
                hostWindowIsKey: self.hostWindow?.isKeyWindow ?? false,
                eventWindowNumber: nil,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            ) else { return }
            self.isCommandPressed = true
        }

        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarCommandHintPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        if resetVisible {
            isCommandPressed = false
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

#if DEBUG
private struct SidebarDevFooter: View {
    @ObservedObject var updateViewModel: UpdateViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UpdatePill(model: updateViewModel)
            Text("THIS IS A DEV BUILD")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.red)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
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

private struct TabItemView: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var tab: Tab
    let index: Int
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let showsCommandShortcutHints: Bool
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    @State private var isHovering = false
    @State private var rowHeight: CGFloat = 1
    @AppStorage(ShortcutHintDebugSettings.sidebarHintXKey) private var sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
    @AppStorage(ShortcutHintDebugSettings.sidebarHintYKey) private var sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage("sidebarShowGitBranch") private var sidebarShowGitBranch = true
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage("sidebarShowBranchDirectory") private var sidebarShowBranchDirectory = true
    @AppStorage("sidebarShowGitBranchIcon") private var sidebarShowGitBranchIcon = false
    @AppStorage("sidebarShowPullRequest") private var sidebarShowPullRequest = true
    @AppStorage(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
    private var openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
    @AppStorage("sidebarShowPorts") private var sidebarShowPorts = true
    @AppStorage("sidebarShowLog") private var sidebarShowLog = true
    @AppStorage("sidebarShowProgress") private var sidebarShowProgress = true
    @AppStorage("sidebarShowStatusPills") private var sidebarShowMetadata = true
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var activeTabIndicatorStyleRaw = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue

    var isActive: Bool {
        tabManager.selectedTabId == tab.id
    }

    var isMultiSelected: Bool {
        selectedTabIds.contains(tab.id)
    }

    private var isBeingDragged: Bool {
        draggedTabId == tab.id
    }

    private var activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: activeTabIndicatorStyleRaw)
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
        usesInvertedActiveForeground ? Color.white.opacity(0.25) : cmuxAccentColor()
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

    private var workspaceShortcutDigit: Int? {
        WorkspaceShortcutMapper.commandDigitForWorkspace(at: index, workspaceCount: tabManager.tabs.count)
    }

    private var showCloseButton: Bool {
        isHovering && tabManager.tabs.count > 1 && !(showsCommandShortcutHints || alwaysShowShortcutHints)
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "⌘\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsCommandShortcutHints || alwaysShowShortcutHints) && workspaceShortcutLabel != nil
    }

    private var workspaceHintSlotWidth: CGFloat {
        SidebarWorkspaceShortcutHintMetrics.slotWidth(
            label: workspaceShortcutLabel,
            debugXOffset: sidebarShortcutHintXOffset
        )
    }

    var body: some View {
        let latestNotificationSubtitle = latestNotificationText
        let compactBranchDirectoryRow = branchDirectoryRow
        let branchDirectoryLines = verticalBranchDirectoryLines
        let branchLinesContainBranch = sidebarShowGitBranch && branchDirectoryLines.contains { $0.branch != nil }

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                let unreadCount = notificationStore.unreadCount(forTabId: tab.id)
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

                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(activeSecondaryColor(0.8))
                }

                Text(tab.title)
                    .font(.system(size: 12.5, weight: titleFontWeight))
                    .foregroundColor(activePrimaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

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
                    .help(KeyboardShortcutSettings.Action.closeWorkspace.tooltip("Close Workspace"))
                    .frame(width: 16, height: 16, alignment: .center)
                    .opacity(showCloseButton && !showsWorkspaceShortcutHint ? 1 : 0)
                    .allowsHitTesting(showCloseButton && !showsWorkspaceShortcutHint)

                    if showsWorkspaceShortcutHint, let workspaceShortcutLabel {
                        Text(workspaceShortcutLabel)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(activePrimaryTextColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ShortcutHintPillBackground(emphasis: shortcutHintEmphasis))
                            .offset(
                                x: ShortcutHintDebugSettings.clamped(sidebarShortcutHintXOffset),
                                y: ShortcutHintDebugSettings.clamped(sidebarShortcutHintYOffset)
                            )
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.14), value: showsCommandShortcutHints || alwaysShowShortcutHints)
                .frame(width: workspaceHintSlotWidth, height: 16, alignment: .trailing)
            }

            if let subtitle = latestNotificationSubtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(activeSecondaryColor(0.8))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }

            if sidebarShowMetadata {
                let metadataEntries = tab.sidebarStatusEntriesInDisplayOrder()
                let metadataBlocks = tab.sidebarMetadataBlocksInDisplayOrder()
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
            if sidebarShowLog, let latestLog = tab.logEntries.last {
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
            if sidebarShowProgress, let progress = tab.progress {
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
            if sidebarShowBranchDirectory {
                if sidebarBranchVerticalLayout {
                    if !branchDirectoryLines.isEmpty {
                        HStack(alignment: .top, spacing: 3) {
                            if sidebarShowGitBranchIcon, branchLinesContainBranch {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 9))
                                    .foregroundColor(activeSecondaryColor(0.6))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(branchDirectoryLines.enumerated()), id: \.offset) { _, line in
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
                } else if let dirRow = compactBranchDirectoryRow {
                    HStack(spacing: 3) {
                        if sidebarShowGitBranch && gitBranchSummaryText != nil && sidebarShowGitBranchIcon {
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
            if sidebarShowPullRequest, !pullRequestDisplays.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(pullRequestDisplays) { pullRequest in
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
                        }
                        .buttonStyle(.plain)
                        .help("Open \(pullRequest.label) #\(pullRequest.number)")
                    }
                }
            }

            // Ports row
            if sidebarShowPorts, !tab.listeningPorts.isEmpty {
                Text(tab.listeningPorts.map { ":\($0)" }.joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(activeSecondaryColor(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tab.logEntries.count)
        .animation(.easeInOut(duration: 0.2), value: tab.progress != nil)
        .animation(.easeInOut(duration: 0.2), value: tab.metadataBlocks.count)
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
        .onDrag {
            #if DEBUG
            dlog("sidebar.onDrag tab=\(tab.id.uuidString.prefix(5))")
            #endif
            draggedTabId = tab.id
            dropIndicator = nil
            return SidebarTabDragPayload.provider(for: tab.id)
        }
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
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityHint(Text("Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."))
        .accessibilityAction(named: Text("Move Up")) {
            moveBy(-1)
        }
        .accessibilityAction(named: Text("Move Down")) {
            moveBy(1)
        }
        .contextMenu {
            let targetIds = contextTargetIds()
            let tabColorPalette = WorkspaceTabColorSettings.palette()
            let shouldPin = !tab.isPinned
            let pinLabel = targetIds.count > 1
                ? (shouldPin ? "Pin Workspaces" : "Unpin Workspaces")
                : (shouldPin ? "Pin Workspace" : "Unpin Workspace")
            let closeLabel = targetIds.count > 1 ? "Close Workspaces" : "Close Workspace"
            let markReadLabel = targetIds.count > 1 ? "Mark Workspaces as Read" : "Mark Workspace as Read"
            let markUnreadLabel = targetIds.count > 1 ? "Mark Workspaces as Unread" : "Mark Workspace as Unread"
            let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
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
                Button("Rename Workspace…") {
                    promptRename()
                }
                .keyboardShortcut(key, modifiers: renameWorkspaceShortcut.eventModifiers)
            } else {
                Button("Rename Workspace…") {
                    promptRename()
                }
            }

            if tab.hasCustomTitle {
                Button("Remove Custom Workspace Name") {
                    tabManager.clearCustomTitle(tabId: tab.id)
                }
            }

            Menu("Workspace Color") {
                if tab.customColor != nil {
                    Button {
                        applyTabColor(nil, targetIds: targetIds)
                    } label: {
                        Label("Clear Color", systemImage: "xmark.circle")
                    }
                }

                Button {
                    promptCustomColor(targetIds: targetIds)
                } label: {
                    Label("Choose Custom Color…", systemImage: "paintpalette")
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

            Divider()

            Button("Move Up") {
                moveBy(-1)
            }
            .disabled(index == 0)

            Button("Move Down") {
                moveBy(1)
            }
            .disabled(index >= tabManager.tabs.count - 1)

            Button("Move to Top") {
                tabManager.moveTabsToTop(Set(targetIds))
                syncSelectionAfterMutation()
            }
            .disabled(targetIds.isEmpty)

            let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
            let windowMoveTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
            let moveMenuTitle = targetIds.count > 1 ? "Move Workspaces to Window" : "Move Workspace to Window"
            Menu(moveMenuTitle) {
                Button("New Window") {
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

            Button("Close Other Workspaces") {
                closeOtherTabs(targetIds)
            }
            .disabled(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count)

            Button("Close Workspaces Below") {
                closeTabsBelow(tabId: tab.id)
            }
            .disabled(index >= tabManager.tabs.count - 1)

            Button("Close Workspaces Above") {
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
        }
    }

    private var backgroundColor: Color {
        switch activeTabIndicatorStyle {
        case .leftRail:
            if isActive        { return Color(nsColor: sidebarSelectedWorkspaceBackgroundNSColor(for: colorScheme)) }
            if isMultiSelected { return cmuxAccentColor().opacity(0.25) }
            return Color.clear
        case .solidFill:
            if isActive { return Color(nsColor: sidebarSelectedWorkspaceBackgroundNSColor(for: colorScheme)) }
            if let custom = resolvedCustomTabColor {
                if isMultiSelected { return custom.opacity(0.35) }
                return custom.opacity(0.7)
            }
            if isMultiSelected { return cmuxAccentColor().opacity(0.25) }
            return Color.clear
        }
    }

    private var railColor: Color {
        explicitRailColor ?? .clear
    }

    private var explicitRailColor: Color? {
        guard activeTabIndicatorStyle == .leftRail,
              let custom = resolvedCustomTabColor else {
            return nil
        }
        return custom.opacity(0.95)
    }

    private var resolvedCustomTabColor: Color? {
        guard let hex = tab.customColor else { return nil }
        return WorkspaceTabColorSettings.displayColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        )
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
        "\(tab.title), workspace \(index + 1) of \(tabManager.tabs.count)"
    }

    private func moveBy(_ delta: Int) {
        let targetIndex = index + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        guard tabManager.reorderWorkspace(tabId: tab.id, toIndex: targetIndex) else { return }
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == tab.id }
        tabManager.selectTab(tab)
        selection = .tabs
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
        selection = .tabs
    }

    private func contextTargetIds() -> [UUID] {
        let baseIds: Set<UUID> = selectedTabIds.contains(tab.id) ? selectedTabIds : [tab.id]
        return tabManager.tabs.compactMap { baseIds.contains($0.id) ? $0.id : nil }
    }

    private func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        let idsToClose = targetIds.filter { id in
            guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return false }
            return allowPinned || !tab.isPinned
        }
        for id in idsToClose {
            if let tab = tabManager.tabs.first(where: { $0.id == id }) {
                tabManager.closeWorkspaceWithConfirmation(tab)
            }
        }
        selectedTabIds.subtract(idsToClose)
        syncSelectionAfterMutation()
    }

    private func closeOtherTabs(_ targetIds: [UUID]) {
        let keepIds = Set(targetIds)
        let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
        closeTabs(idsToClose, allowPinned: false)
    }

    private func closeTabsBelow(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
        closeTabs(idsToClose, allowPinned: false)
    }

    private func closeTabsAbove(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
        closeTabs(idsToClose, allowPinned: false)
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

    private func hasUnreadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && !$0.isRead }
    }

    private func hasReadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && $0.isRead }
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

    private var latestNotificationText: String? {
        guard let notification = notificationStore.latestNotification(forTabId: tab.id) else { return nil }
        let text = notification.body.isEmpty ? notification.title : notification.body
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var branchDirectoryRow: String? {
        var parts: [String] = []

        // Git branch (if enabled and available)
        if sidebarShowGitBranch, let gitSummary = gitBranchSummaryText {
            parts.append(gitSummary)
        }

        // Directory summary
        if let dirs = directorySummaryText {
            parts.append(dirs)
        }

        let result = parts.joined(separator: " · ")
        return result.isEmpty ? nil : result
    }

    private var gitBranchSummaryText: String? {
        let lines = gitBranchSummaryLines
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private var gitBranchSummaryLines: [String] {
        tab.sidebarGitBranchesInDisplayOrder().map { branch in
            "\(branch.branch)\(branch.isDirty ? "*" : "")"
        }
    }

    private var verticalBranchDirectoryEntries: [SidebarBranchOrdering.BranchDirectoryEntry] {
        tab.sidebarBranchDirectoryEntriesInDisplayOrder()
    }

    private struct VerticalBranchDirectoryLine {
        let branch: String?
        let directory: String?
    }

    private var verticalBranchDirectoryLines: [VerticalBranchDirectoryLine] {
        let home = SidebarPathFormatter.homeDirectoryPath
        return verticalBranchDirectoryEntries.compactMap { entry in
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
                return VerticalBranchDirectoryLine(branch: branch, directory: directory)
            case let (branch?, nil):
                return VerticalBranchDirectoryLine(branch: branch, directory: nil)
            case let (nil, directory?):
                return VerticalBranchDirectoryLine(branch: nil, directory: directory)
            default:
                return nil
            }
        }
    }

    private var directorySummaryText: String? {
        guard !tab.panels.isEmpty else { return nil }
        let home = SidebarPathFormatter.homeDirectoryPath
        var seen: Set<String> = []
        var entries: [String] = []
        for panelId in tab.sidebarOrderedPanelIds() {
            let directory = tab.panelDirectories[panelId] ?? tab.currentDirectory
            let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
            guard !shortened.isEmpty else { continue }
            if seen.insert(shortened).inserted {
                entries.append(shortened)
            }
        }
        return entries.isEmpty ? nil : entries.joined(separator: " | ")
    }

    private struct PullRequestDisplay: Identifiable {
        let id: String
        let number: Int
        let label: String
        let url: URL
        let status: SidebarPullRequestStatus
    }

    private var pullRequestDisplays: [PullRequestDisplay] {
        tab.sidebarPullRequestsInDisplayOrder().map { pullRequest in
            PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status
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

    private func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return "open"
        case .merged: return "merged"
        case .closed: return "closed"
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

    private func promptCustomColor(targetIds: [UUID]) {
        let alert = NSAlert()
        alert.messageText = "Custom Workspace Color"
        alert.informativeText = "Enter a hex color in the format #RRGGBB."

        let seed = tab.customColor ?? WorkspaceTabColorSettings.customColors().first ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

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
        alert.messageText = "Invalid Color"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = "Enter a hex color in the format #RRGGBB."
        } else {
            alert.informativeText = "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB."
        }
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a custom name for this workspace."
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = "Workspace name"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
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
                Button(isExpanded ? "Show less" : "Show more") {
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
        .help(helpText)
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
                .help(url.absoluteString)
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
                Button(isExpanded ? "Show less details" : "Show more details") {
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

enum SidebarDropEdge {
    case top
    case bottom
}

struct SidebarDropIndicator {
    let tabId: UUID?
    let edge: SidebarDropEdge
}

enum SidebarDropPlanner {
    static func indicator(
        draggedTabId: UUID?,
        targetTabId: UUID?,
        tabIds: [UUID],
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

        let targetIndex = resolvedTargetIndex(from: fromIndex, insertionPosition: insertionPosition, totalCount: tabIds.count)
        guard targetIndex != fromIndex else { return nil }
        return indicatorForInsertionPosition(insertionPosition, tabIds: tabIds)
    }

    static func targetIndex(
        draggedTabId: UUID,
        targetTabId: UUID?,
        indicator: SidebarDropIndicator?,
        tabIds: [UUID]
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

        return resolvedTargetIndex(from: fromIndex, insertionPosition: insertionPosition, totalCount: tabIds.count)
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
            tabIds: tabIds
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
        dropIndicator = SidebarDropPlanner.indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
            tabIds: tabIds,
            pointerY: targetTabId == nil ? nil : info.location.y,
            targetHeight: targetRowHeight
        )
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
            .help("Drag to open in Finder or another app")
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
                    displayName = "Macintosh HD"
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

private struct SidebarBackdrop: View {
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = 0.18
    @AppStorage("sidebarTintHex") private var sidebarTintHex = "#000000"
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0

    var body: some View {
        let materialOption = SidebarMaterialOption(rawValue: sidebarMaterial)
        let blendingMode = SidebarBlendModeOption(rawValue: sidebarBlendMode)?.mode ?? .behindWindow
        let state = SidebarStateOption(rawValue: sidebarState)?.state ?? .active
        let tintColor = (NSColor(hex: sidebarTintHex) ?? .black).withAlphaComponent(sidebarTintOpacity)
        let cornerRadius = CGFloat(max(0, sidebarCornerRadius))
        let useLiquidGlass = materialOption?.usesLiquidGlass ?? false
        let useWindowLevelGlass = useLiquidGlass && blendingMode == .behindWindow

        return ZStack {
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
        case .none: return "None"
        case .liquidGlass: return "Liquid Glass (macOS 26+)"
        case .sidebar: return "Sidebar"
        case .hudWindow: return "HUD Window"
        case .menu: return "Menu"
        case .popover: return "Popover"
        case .underWindowBackground: return "Under Window"
        case .windowBackground: return "Window Background"
        case .contentBackground: return "Content Background"
        case .fullScreenUI: return "Full Screen UI"
        case .sheet: return "Sheet"
        case .headerView: return "Header View"
        case .toolTip: return "Tool Tip"
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
        case .behindWindow: return "Behind Window"
        case .withinWindow: return "Within Window"
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
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .followWindow: return "Follow Window"
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
        case .nativeSidebar: return "Native Sidebar"
        case .glassBehind: return "Raycast Gray"
        case .softBlur: return "Soft Blur"
        case .popoverGlass: return "Popover Glass"
        case .hudGlass: return "HUD Glass"
        case .underWindow: return "Under Window"
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
    func hexString() -> String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            min(255, max(0, Int(red * 255))),
            min(255, max(0, Int(green * 255))),
            min(255, max(0, Int(blue * 255)))
        )
    }
}
