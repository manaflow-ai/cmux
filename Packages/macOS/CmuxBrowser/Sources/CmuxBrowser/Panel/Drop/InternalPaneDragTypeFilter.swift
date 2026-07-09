public import AppKit

/// Selects which dragged pasteboard types a hosted web view is allowed to
/// register for.
///
/// A `WKWebView` inherently registers for `public.text` (and related text
/// types). Bonsplit tab drags use `NSString` (`public.utf8-plain-text`), which
/// conforms to `public.text`, so AppKit's view-hierarchy drag routing delivers
/// the session to the web view instead of SwiftUI's sibling `.onDrop` overlays
/// (AppKit bubbles only through superviews, not siblings). Filtering the
/// text-based types out of the registration keeps tab drags flowing to the
/// overlays while still registering file-URL types so Finder file drops and
/// HTML drag-and-drop continue to work.
public struct InternalPaneDragTypeFilter: Sendable, Equatable {
    /// The pasteboard types that must be filtered out of a web view's drag
    /// registration because they collide with Bonsplit tab drags or sidebar
    /// tab reorders.
    public let blockedTypes: Set<NSPasteboard.PasteboardType>

    public init(blockedTypes: Set<NSPasteboard.PasteboardType>) {
        self.blockedTypes = blockedTypes
    }

    /// The default set of conflicting drag types: plain-text variants that match
    /// Bonsplit's `NSString` tab drags plus the custom tab-transfer and
    /// sidebar-reorder pasteboard types.
    public static let standard = InternalPaneDragTypeFilter(blockedTypes: [
        .string, // public.utf8-plain-text — matches bonsplit's NSString tab drags
        NSPasteboard.PasteboardType("public.text"),
        NSPasteboard.PasteboardType("public.plain-text"),
        NSPasteboard.PasteboardType("com.splittabbar.tabtransfer"),
        NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder"),
    ])

    /// Returns the dragged types that are safe to register for, dropping every
    /// blocked type.
    public func allowedTypes(
        from newTypes: [NSPasteboard.PasteboardType]
    ) -> [NSPasteboard.PasteboardType] {
        newTypes.filter { !blockedTypes.contains($0) }
    }
}
