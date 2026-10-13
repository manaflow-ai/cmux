public import AppKit

/// A toolbar control whose hover follows the pointer (`OmnibarPointer`).
@MainActor
protocol PointerHoverReporting: NSView {
    var isPointerHovering: Bool { get }
}

extension ChromeIconButton: PointerHoverReporting {
    var isPointerHovering: Bool { isHovering }
}

extension OmnibarPillView: PointerHoverReporting {
    var isPointerHovering: Bool { debugHovering }
}

/// What `debug.omnibar` reports about the pointer over the browser toolbar
/// (`OmnibarPointer`, the live check `omnibar-pointer-live.py`): which
/// controls show hover, the region and cursor the rules give at a probe
/// point, and where the parts are, in window points from the top left
/// (the coordinates `debug.mouse` takes).
public struct BrowserPointerDebug: Sendable, Equatable {
    /// The omnibar's own hover lift.
    public var barHovering: Bool
    /// Identifiers of the toolbar buttons that show hover now.
    public var hoveredButtons: [String]
    /// The region (`text`, `bar`, `control`, `toolbar`, `outside`) and the
    /// cursor (`arrow`, `iBeam`) at the probe point.
    public var probeRegion: String?
    public var probeCursor: String?
    /// Part name to frame (x, y, width, height).
    public var frames: [String: CGRect]
}

extension BrowserChromeView {
    /// The pointer report; `probe` is a window point from the top left.
    public func debugPointer(probe: CGPoint?) -> BrowserPointerDebug {
        var hovered: [String] = []
        var stack: [NSView] = [toolbar]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard let control = view as? any PointerHoverReporting, !(view is OmnibarPillView), control.isPointerHovering else { continue }
            let id = view.accessibilityIdentifier()
            hovered.append(id.isEmpty ? String(describing: type(of: view)) : id)
        }
        var frames: [String: CGRect] = [:]
        func record(_ name: String, _ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor, let rect = topLeftFrame(of: view) else { return }
            frames[name] = rect
        }
        record("toolbar", toolbar)
        record("bar", addressBar)
        record("text", addressBar.field)
        record("star", addressBar.starButton)
        record("chip", addressBar.pageInfoAnchor)
        for button in [backButton, forwardButton, reloadButton] { record(button.accessibilityIdentifier(), button) }
        for button in BrowserToolbarButton.allCases {
            if let view = toolbarButtons.button(button) { record(button.identifier, view) }
        }
        let probed = probe.flatMap(region(atTopLeft:))
        return BrowserPointerDebug(
            barHovering: addressBar.pill.debugHovering,
            hoveredButtons: hovered.sorted(),
            probeRegion: probed?.rawValue ?? (probe == nil ? nil : "outside"),
            probeCursor: probed.map { OmnibarPointer.cursor($0, editing: addressBar.isEditing).rawValue },
            frames: frames
        )
    }

    private func topLeftFrame(of view: NSView) -> CGRect? {
        guard let window, let content = window.contentView else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The region the cursor rules see at a window point from the top left:
    /// the view AppKit hits there, classified.
    private func region(atTopLeft point: CGPoint) -> OmnibarPointer.Region? {
        guard let window, let content = window.contentView else { return nil }
        let base = NSPoint(x: point.x, y: content.bounds.height - point.y)
        guard let hit = content.hitTest(content.convert(base, from: nil)), hit.isDescendant(of: toolbar) else { return nil }
        let field = addressBar.field
        if hit === field || hit.isDescendant(of: field) { return .text }
        if hit === addressBar { return .bar }
        var view: NSView? = hit
        while let current = view, current !== toolbar {
            if current is NSControl || current is any PointerHoverReporting || current is ProfileBadgeView || current is MachineBadgeView {
                return .control
            }
            view = current.superview
        }
        return .toolbar
    }
}
