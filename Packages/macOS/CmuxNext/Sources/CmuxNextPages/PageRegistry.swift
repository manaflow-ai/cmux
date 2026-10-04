import AppKit

/// The live page views, for the generic page debug verb and the key dispatcher's lookups.
@MainActor
public enum PageRegistry {
    private static let views = NSHashTable<PageWebView>.weakObjects()

    static func add(_ view: PageWebView) { views.add(view) }

    /// Live views of page `id` (every page when nil), oldest first.
    public static func pages(id: String? = nil) -> [PageWebView] {
        views.allObjects.filter { id == nil || $0.pageID == id }
    }
}
