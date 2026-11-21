public import AppKit
import CmuxNextDesignTokens

/// The Customize… element under a point: one of the Rust element map's ids
/// (cmux-action-catalog `customize_elements`, the catalog's `customize_elements`) and the
/// element's frame. The Customize Inspector (hold Option over the window) and its tests ask
/// the window's views for it; nothing else runs it.
public struct CustomizeElementHit: Equatable, Sendable {
    /// The element map id (`sidebar`, `tab`, `chatComposer`…).
    public var id: String
    /// The element's frame, in the coordinates of the view that answered (window coordinates
    /// once ``resolve(in:at:)`` returns it).
    public var frame: NSRect

    public init(id: String, frame: NSRect) {
        self.id = id
        self.frame = frame
    }

    /// Every element id a view of the main window answers: the sidebar's (`SidebarView`, its list
    /// and regions), the tab strip's, the agent pane's, a pane's content and the title bar views'
    /// identifiers. `CustomizeInspectorTests` holds it equal to the Rust element map, so an element
    /// the map gains with no view to answer it fails there.
    public static let answeredIDs: Set<String> = [
        "sidebar", "widget", "workspaceRow", "sidebarSection", "tab", "tabBar", "pane", "titlebar", "chatComposer", "chatMessages",
    ]

    /// The `NSView.identifier` prefix a view whose whole bounds are one element carries
    /// (`cmux.customize.pane`): no code of its own, the identifier is the answer.
    public static let identifierPrefix = "cmux.customize."

    /// The identifier that marks a view as the element `id`.
    public static func identifier(_ id: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(identifierPrefix + id)
    }

    /// The innermost element under `point` (window coordinates) in `window`: the view the
    /// point hits, then its superviews, each answering through ``CustomizeElementPointing``
    /// or its identifier. The frame comes back in window coordinates. Nil over a part with
    /// no element (a gap the map has no entry for).
    @MainActor
    public static func resolve(in window: NSWindow, at point: NSPoint) -> CustomizeElementHit? {
        guard let content = window.contentView, let root = content.superview ?? Optional(content),
              let hit = root.hitTest(point) else { return nil }
        for view in sequence(first: hit, next: \.superview) {
            if let found = element(of: view, at: view.convert(point, from: nil)) {
                return CustomizeElementHit(id: found.id, frame: view.convert(found.frame, to: nil))
            }
        }
        return nil
    }

    /// What `view` itself answers for `point` (its own coordinates), without its superviews.
    @MainActor
    public static func element(of view: NSView, at point: NSPoint) -> CustomizeElementHit? {
        if let pointing = view as? CustomizeElementPointing, let hit = pointing.customizeElement(at: point) {
            return hit
        }
        // A pane's content view (the App's PaneContentView, a browser's chrome) is the pane.
        if view is PaneContentChrome { return CustomizeElementHit(id: "pane", frame: view.bounds) }
        guard let raw = view.identifier?.rawValue, raw.hasPrefix(identifierPrefix) else { return nil }
        return CustomizeElementHit(id: String(raw.dropFirst(identifierPrefix.count)), frame: view.bounds)
    }
}

/// A view that holds more than one Customize… element (a tab strip: each tab and the bar), so
/// an identifier cannot say which: it names the element under a point itself.
@MainActor
public protocol CustomizeElementPointing: AnyObject {
    /// The element under `point` (this view's coordinates) with its frame in this view's
    /// coordinates, or nil to let the superview answer.
    func customizeElement(at point: NSPoint) -> CustomizeElementHit?
}
