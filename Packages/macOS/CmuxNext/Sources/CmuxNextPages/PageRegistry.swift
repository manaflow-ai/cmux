import AppKit

/// The live page views, for the generic page debug verb and the key dispatcher's lookups.
@MainActor
public struct PageRegistry {
    public init() {}
    private static let views = NSHashTable<PageWebView>.weakObjects()
    /// Creation order of the live views (``instance(of:)``).
    private static var serials: [ObjectIdentifier: UInt64] = [:]
    private static var nextSerial: UInt64 = 0

    static func add(_ view: PageWebView) {
        views.add(view)
        nextSerial += 1
        serials[ObjectIdentifier(view)] = nextSerial
        if serials.count > 2 * views.count + 16 {
            let live = Set(views.allObjects.map(ObjectIdentifier.init))
            serials = serials.filter { live.contains($0.key) }
        }
    }

    /// A stable number for a live view, in creation order (the `instance` of `debug.page`).
    public static func instance(of view: PageWebView) -> UInt64 {
        serials[ObjectIdentifier(view)] ?? 0
    }

    /// Live views of page `id` (every page when nil), oldest first; for a probe, none that refuses one.
    public static func pages(id: String? = nil, probing: Bool = false) -> [PageWebView] {
        views.allObjects.filter { (id == nil || $0.pageID == id) && !(probing && $0.refusesProbes) }
            .sorted { instance(of: $0) < instance(of: $1) }
    }

    /// The page a probe means: `instance` when given; else a page that is not the parked spare (the
    /// spare when `parked`), the newest shown one in the key window first (``choose(_:inKeyWindow:hidden:)``). The parked spare runs
    /// its document with no routes, so a probe that read it reported state no visible page showed.
    public static func probeTarget(id: String?, parked: Bool = false, instance: UInt64? = nil) -> PageWebView? {
        let live = pages(id: id, probing: true)
        if let instance { return live.first { Self.instance(of: $0) == instance } }
        let candidates = live.filter { $0.isParkedSpare == parked }
        return choose(candidates, inKeyWindow: { $0.window?.isKeyWindow == true },
                      hidden: { $0.isHiddenOrHasHiddenAncestor })
    }

    /// Which of `candidates` (oldest first) a probe reads: the newest shown page in the key window, else
    /// the newest shown page, else the newest. A window holds every chat it ever opened, hidden ones too:
    /// the oldest page in the key window was an earlier, hidden chat, so a wait for a new reply read a
    /// page that never showed it and timed out (markdown-table-motion on cmux18).
    static func choose<Page>(_ candidates: [Page], inKeyWindow: (Page) -> Bool, hidden: (Page) -> Bool) -> Page? {
        let shown = candidates.filter { !hidden($0) }
        return shown.last(where: inKeyWindow) ?? shown.last ?? candidates.last
    }
}
