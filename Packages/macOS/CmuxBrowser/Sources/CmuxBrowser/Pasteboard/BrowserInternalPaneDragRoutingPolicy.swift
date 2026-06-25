public import AppKit

/// Decides which pasteboard drag types a browser web view must refuse so that
/// cmux's own internal pane drags never get swallowed by WebKit.
///
/// WebKit's `WKWebView` inherently calls `registerForDraggedTypes` with
/// `public.text` (and related text identifiers). Bonsplit tab drags carry
/// `NSString` (`public.utf8-plain-text`, which conforms to `public.text`), so
/// AppKit's view-hierarchy drag routing would deliver those sessions to the web
/// view instead of SwiftUI's sibling `.onDrop` overlays. Rejecting in
/// `draggingEntered` does not help because AppKit only bubbles up through
/// superviews, not siblings. The fix is to filter the conflicting text-based
/// types out of the web view's registration and to reject any in-flight drag
/// that carries one of cmux's internal pane-transfer identifiers, while still
/// keeping file/URL types so Finder file drops and HTML drag-and-drop work.
///
/// The identifier strings are carried here as the policy's own constants because
/// they are the stable wire contract already inlined at the drag boundary; the
/// policy is intentionally free of any sidebar/tab-bar module dependency.
public struct BrowserInternalPaneDragRoutingPolicy: Sendable {
    /// `public.utf8-plain-text`, the type Bonsplit's `NSString` tab drags expose
    /// (and the value of `NSPasteboard.PasteboardType.string`).
    private static let utf8PlainTextIdentifier = "public.utf8-plain-text"
    /// `public.text`, the umbrella text identifier WebKit registers for.
    private static let textIdentifier = "public.text"
    /// `public.plain-text`, the legacy plain-text identifier.
    private static let plainTextIdentifier = "public.plain-text"
    /// `com.splittabbar.tabtransfer`, Bonsplit's tab-transfer drag identifier.
    private static let bonsplitTabTransferIdentifier = "com.splittabbar.tabtransfer"
    /// `com.cmux.sidebar-tab-reorder`, cmux's sidebar tab-reorder drag identifier.
    private static let sidebarTabReorderIdentifier = "com.cmux.sidebar-tab-reorder"

    private static let bonsplitTabTransferType =
        NSPasteboard.PasteboardType(bonsplitTabTransferIdentifier)
    private static let sidebarTabReorderType =
        NSPasteboard.PasteboardType(sidebarTabReorderIdentifier)

    /// Creates a routing policy. The policy is stateless beyond its fixed wire
    /// identifiers, so a single instance can be held and reused.
    public init() {}

    /// The text-based pasteboard types a browser web view must NOT register for,
    /// because they collide with cmux's internal pane and sidebar tab drags.
    ///
    /// Keep file/URL/image/HTML types out of this set so external Finder drops
    /// and HTML drag-and-drop continue to reach the web view.
    public var blockedDragTypes: Set<NSPasteboard.PasteboardType> {
        [
            .string, // public.utf8-plain-text — matches Bonsplit's NSString tab drags
            NSPasteboard.PasteboardType(Self.textIdentifier),
            NSPasteboard.PasteboardType(Self.plainTextIdentifier),
            Self.bonsplitTabTransferType,
            Self.sidebarTabReorderType,
        ]
    }

    /// Whether an in-flight drag carrying these pasteboard types is one of cmux's
    /// internal pane transfers (a Bonsplit tab transfer or a sidebar tab reorder)
    /// and must be rejected by the web view's dragging-info overrides.
    public func shouldRejectInternalPaneDrag(
        _ pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(Self.bonsplitTabTransferType)
            || pasteboardTypes.contains(Self.sidebarTabReorderType)
    }
}
