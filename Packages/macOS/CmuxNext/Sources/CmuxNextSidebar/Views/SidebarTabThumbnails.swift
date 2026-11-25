public import CoreGraphics

/// Pictures of tabs for the hover card's split miniature (``WorkspacePaneShapeView``, #51768): each tile shows its
/// pane's front tab as it last looked, not only its kind's mark.
///
/// The sidebar's hover card controller owns one; the app sets its ``provider`` (`SidebarView.tabPictures`) (its tab previews: a terminal's live frame, a page's capture, a chat's picture). Every
/// card shares the pictures kept here, so a card opened again draws its last pictures at once, with no empty
/// frame, while it asks for newer ones; a reply with no picture keeps the one shown.
///
/// ```swift
/// sidebarView.tabPictures = { tab, size in await previews.image(of: tab, size) }
/// ```
@MainActor
public final class SidebarTabThumbnails {
    /// A tab's picture at most `maxPixelSize`; nil when the tab has none to show (a blank page, a remote tab).
    public typealias Provider = @MainActor (TabID, CGSize) async -> CGImage?

    /// Where pictures come from; nil draws marks only.
    public var provider: Provider?

    /// How long after its last pictures a showing card asks for newer ones (a running terminal, a chat that moved
    /// on). Without the pane picture schedule (`PanePictures.isEnabled`) every ask is a capture, so the app asks
    /// less often (``uncachedRefreshInterval``).
    public var refreshInterval: Duration = SidebarTabThumbnails.cachedRefreshInterval
    public static let cachedRefreshInterval: Duration = .seconds(1)

    /// How many tabs' pictures stay: a few cards' worth, about 6 MB at most of 640 px pictures.
    static let capacity = 24

    private var images: [TabID: CGImage] = [:]
    /// Least recently asked first.
    private var order: [TabID] = []
    private var inFlight: Set<TabID> = []

    public init(provider: Provider? = nil) { self.provider = provider }

    /// `tab`'s last picture, if any.
    public func image(for tab: TabID) -> CGImage? { images[tab] }

    /// Asks ``provider`` for `tab`'s picture now, one request per tab at a time. True when a new picture replaced the
    /// shown one; a nil reply or the same image keeps it (no flash back to the mark).
    @discardableResult
    func refresh(_ tab: TabID, maxPixelSize: CGSize) async -> Bool {
        guard let provider, inFlight.insert(tab).inserted else { return false }
        defer { inFlight.remove(tab) }
        guard let image = await provider(tab, maxPixelSize) else { return false }
        let isNew = images[tab] !== image
        store(image, for: tab)  // also marks it the most recently asked
        return isNew
    }

    private func store(_ image: CGImage, for tab: TabID) {
        if images.updateValue(image, forKey: tab) != nil { order.removeAll { $0 == tab } }
        order.append(tab)
        while order.count > Self.capacity { images[order.removeFirst()] = nil }
    }
}
