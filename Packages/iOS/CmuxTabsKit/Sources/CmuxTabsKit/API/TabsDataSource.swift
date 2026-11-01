#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// What a client implements to drive a `TabsView`. Make the conforming
/// class `@Observable`: the view re-renders from whatever it reads here.
///
/// Required: `tabs`, `activeTabID`, `newTabOptions`, `activate`, `close`,
/// `createTab` and `content(for:context:)`. Everything else has a default.
@MainActor
public protocol TabsDataSource: AnyObject, Observable {
    /// The live page of a tab.
    associatedtype Content: View
    /// A tab's card in the grid (and the neighbor page during a toolbar swipe).
    associatedtype Card: View = TabsKitThumbnailCard
    /// A row above the toolbar for the active tab (a composer, a key bar).
    associatedtype Accessory: View = EmptyView
    /// What covers the page while the address is being edited.
    associatedtype EditingBackground: View = TabsKitAddressSuggestions

    /// Tabs in grid order (new tabs go last, as in Safari).
    var tabs: [TabsKitTab] { get }
    /// The tab on screen; nil only when there are no tabs.
    var activeTabID: TabsKitTab.ID? { get }
    /// The (+) button's options. The first is the default kind.
    var newTabOptions: [TabsKitNewTabOption] { get }

    /// Makes `id` the active tab (a card tapped, a swipe, a suggestion).
    func activate(_ id: TabsKitTab.ID)
    /// Closes `id` and returns true once it is gone from `tabs` (when it
    /// was active, pick the next active tab). For Safari's timing take it
    /// out of `tabs` at once (the count changes and the grid reflows while
    /// a swiped card is still flying off) and confirm with your backend
    /// afterwards. Return false when the close was refused: put the tab
    /// back in `tabs`, its card springs back to its slot, and the kit shows
    /// your `notice` (set it to say why).
    func close(_ id: TabsKitTab.ID) async -> Bool
    /// Creates a tab, appends it to `tabs`, makes it active and returns its
    /// id; nil when it could not be created (the grid stays as it was).
    func createTab(_ option: TabsKitNewTabOption) async -> TabsKitTab.ID?

    /// The live page, laid out at the full screen size (draw under the
    /// status bar and the toolbar; `context.safeAreaInsets` says how much
    /// they cover). The kit scales it into the zooming rect, so it must not
    /// depend on its on-screen size.
    @ViewBuilder func content(for tab: TabsKitTab, context: TabsKitContentContext) -> Content

    /// The tab's card, laid out at the full screen size like `content` and
    /// scaled down by the kit. The default shows `thumbnail(for:)`.
    @ViewBuilder func card(for tab: TabsKitTab) -> Card
    /// The card's content anchor: how far (page points) the card, and the
    /// live page as it zooms into a card, move the tab's content up, for a
    /// card that shows only the top `visibleHeight` points of the page
    /// (status bar included). A terminal returns what brings its prompt
    /// into view, so its card shows the screen you left, not its top rows.
    /// The zoom moves it with the scale (none full screen). Default 0.
    func cardContentOffset(for id: TabsKitTab.ID, visibleHeight: CGFloat) -> CGFloat
    /// A snapshot of the tab's page at full screen size for the default card.
    func thumbnail(for id: TabsKitTab.ID) -> UIImage?
    /// The tab grid is about to appear: refresh thumbnails now (once per
    /// opening; cards are not expected to update while the grid shows).
    func overviewWillAppear()
    /// The grid became visible (true) or was covered by a page (false):
    /// stop any card rendering while it is hidden. Default: nothing.
    func overviewVisibilityChanged(_ visible: Bool)
    /// The grid started (true) or stopped (false) scrolling: hold card
    /// updates until it stops, so none lands in a scroll frame.
    func overviewScrollingChanged(_ scrolling: Bool)
    /// The grid settled and is not scrolling (true), or a zoom, a scroll or
    /// the page took over (false): deferred card work (rendering a card's
    /// snapshot) runs only while this is true. Default: nothing.
    func overviewIdleChanged(_ idle: Bool)
    /// The grid settled with `id` active. Return true after making the
    /// tab's card show the live content's current frame (`thumbnail` or
    /// `card`) and pausing the live content (it keeps showing that frame):
    /// the kit then shows the static card and hides the live page until
    /// the grid is left (`resumeLiveContent`). Default false: the active
    /// card is the live page itself.
    func showStaticCard(for id: TabsKitTab.ID) -> Bool
    /// The grid is being left after `showStaticCard(for:)` returned true:
    /// the live content draws again (the zoom starts from its last frame,
    /// the same pixels as the card).
    func resumeLiveContent(_ id: TabsKitTab.ID)

    /// A row above the toolbar for the active tab. Default: none.
    @ViewBuilder func accessory(for tab: TabsKitTab, context: TabsKitContentContext) -> Accessory
    /// Shown over the page while the address field is focused. The default
    /// lists matching open tabs and a Search row.
    @ViewBuilder func editingBackground(_ editing: TabsKitAddressEditing) -> EditingBackground

    /// Back / forward (`TabsKitTabFeatures.history`).
    func goBack(_ id: TabsKitTab.ID)
    func goForward(_ id: TabsKitTab.ID)
    /// True when `history(_:for:)` returns lists: long-pressing back or
    /// forward then shows them in a menu.
    var providesHistoryMenus: Bool { get }
    /// The back or forward list, nearest entry first.
    func history(_ direction: TabsKitHistoryDirection, for id: TabsKitTab.ID) -> [TabsKitHistoryItem]
    func goToHistoryItem(_ item: TabsKitHistoryItem, in id: TabsKitTab.ID)
    /// The address field's Go key (`TabsKitTabFeatures.addressEditing`):
    /// a URL or a search.
    func navigate(_ id: TabsKitTab.ID, to text: String)
    /// Reload, or stop while loading (`TabsKitTabFeatures.reload`).
    func reloadOrStop(_ id: TabsKitTab.ID)
    /// The page menu's groups (`TabsKitTabFeatures.pageMenu`).
    func pageMenu(for tab: TabsKitTab) -> [[TabsKitMenuItem]]
    /// False while a tab's live content would show nothing yet (a terminal
    /// still attaching): the kit keeps the tab's card over it, so opening a
    /// card never flashes blank. Default true.
    func isContentReady(_ id: TabsKitTab.ID) -> Bool
    /// Groups of items above Close Tab and Close Other Tabs in a card's
    /// long-press menu (Safari: Copy Link, Duplicate Tab). Default none.
    func cardMenu(for tab: TabsKitTab) -> [[TabsKitMenuItem]]
    /// Pinned tabs (Safari's pinned area above the grid): list them first in
    /// `tabs`. With `supportsPinning` the card menu offers Pin / Unpin Tab
    /// and Select Tabs offers Pin N Tabs.
    var pinnedTabIDs: Set<TabsKitTab.ID> { get }
    var supportsPinning: Bool { get }
    /// Pin or unpin tabs (move pinned ones to the front of `tabs`).
    func setPinned(_ ids: [TabsKitTab.ID], _ pinned: Bool)
    /// The links Select Tabs' Copy N Links puts on the pasteboard; empty
    /// hides the item.
    func links(for ids: [TabsKitTab.ID]) -> [URL]
    /// True when cards can be dragged to a new slot (long press, then move).
    var supportsReordering: Bool { get }
    /// A dragged card moved to `index` in `tabs`: reorder `tabs`.
    func moveTab(_ id: TabsKitTab.ID, to index: Int)
    /// A short message the kit shows as a glass toast at the top (a tab that
    /// could not be created, a step that failed). Set it when `createTab`
    /// returns nil so the user learns why; the grid stays as it was.
    var notice: String? { get }
    /// The toast was tapped away or timed out (5 s).
    func clearNotice()
}

extension TabsDataSource where Card == TabsKitThumbnailCard {
    public func card(for tab: TabsKitTab) -> TabsKitThumbnailCard {
        TabsKitThumbnailCard(tab: tab, image: thumbnail(for: tab.id))
    }
}

extension TabsDataSource where Accessory == EmptyView {
    public func accessory(for tab: TabsKitTab, context: TabsKitContentContext) -> EmptyView { EmptyView() }
}

extension TabsDataSource where EditingBackground == TabsKitAddressSuggestions {
    public func editingBackground(_ editing: TabsKitAddressEditing) -> TabsKitAddressSuggestions {
        TabsKitAddressSuggestions(editing)
    }
}

extension TabsDataSource {
    public func thumbnail(for id: TabsKitTab.ID) -> UIImage? { nil }
    public func cardContentOffset(for id: TabsKitTab.ID, visibleHeight: CGFloat) -> CGFloat { 0 }
    public func overviewWillAppear() {}
    public func overviewVisibilityChanged(_ visible: Bool) {}
    public func overviewScrollingChanged(_ scrolling: Bool) {}
    public func overviewIdleChanged(_ idle: Bool) {}
    public func showStaticCard(for id: TabsKitTab.ID) -> Bool { false }
    public func resumeLiveContent(_ id: TabsKitTab.ID) {}
    public func goBack(_ id: TabsKitTab.ID) {}
    public func goForward(_ id: TabsKitTab.ID) {}
    public var providesHistoryMenus: Bool { false }
    public func history(_ direction: TabsKitHistoryDirection, for id: TabsKitTab.ID) -> [TabsKitHistoryItem] { [] }
    public func goToHistoryItem(_ item: TabsKitHistoryItem, in id: TabsKitTab.ID) {}
    public func navigate(_ id: TabsKitTab.ID, to text: String) {}
    public func reloadOrStop(_ id: TabsKitTab.ID) {}
    public func pageMenu(for tab: TabsKitTab) -> [[TabsKitMenuItem]] { [] }
    public func isContentReady(_ id: TabsKitTab.ID) -> Bool { true }
    public func cardMenu(for tab: TabsKitTab) -> [[TabsKitMenuItem]] { [] }
    public var supportsReordering: Bool { false }
    public var pinnedTabIDs: Set<TabsKitTab.ID> { [] }
    public var supportsPinning: Bool { false }
    public func setPinned(_ ids: [TabsKitTab.ID], _ pinned: Bool) {}
    public func links(for ids: [TabsKitTab.ID]) -> [URL] { [] }
    public func moveTab(_ id: TabsKitTab.ID, to index: Int) {}
    public var notice: String? { nil }
    public func clearNotice() {}
}

extension EnvironmentValues {
    /// The page size a tab's card content is laid out at when the kit scales the full page into
    /// it: set on the grid's cards and on the zoom's and swipe's cards. Nil where a card is laid
    /// out at its own size (its long-press menu preview and its drag preview), so a card never
    /// takes its own size for the page's.
    @Entry public var tabsKitCardPageSize: CGSize? = nil
}

/// Where and how a tab's live page is shown.
public struct TabsKitContentContext {
    /// The full screen size the content is laid out at.
    public var pageSize: CGSize
    /// Status bar (top) and toolbar (bottom) heights over the content.
    public var safeAreaInsets: EdgeInsets
    /// The page is settled full screen and takes input (no zoom, swipe or menu).
    public var isInteractive: Bool
    /// A pinch is driving the tab zoom: stop the content's own pinch zoom
    /// (for a web view, disable its pinch recognizer while this is true).
    public var isZoomGestureActive: Bool
    /// The toolbar is collapsed into the pill.
    public var isToolbarCollapsed: Bool
    let onScroll: @MainActor (CGFloat) -> Void

    init(pageSize: CGSize, safeAreaInsets: EdgeInsets, isInteractive: Bool, isZoomGestureActive: Bool, isToolbarCollapsed: Bool,
         onScroll: @escaping @MainActor (CGFloat) -> Void) {
        self.pageSize = pageSize
        self.safeAreaInsets = safeAreaInsets
        self.isInteractive = isInteractive
        self.isZoomGestureActive = isZoomGestureActive
        self.isToolbarCollapsed = isToolbarCollapsed
        self.onScroll = onScroll
    }

    /// Report the user's finger travel on the content (points; positive =
    /// finger moving down, revealing content above). About 15 pt up collapses
    /// the toolbar and 6 pt down expands it, as in Safari.
    @MainActor public func reportScroll(fingerDelta: CGFloat) {
        onScroll(fingerDelta)
    }
}

extension View {
    /// Collapses and expands the toolbar from a SwiftUI scroll view's
    /// content offset. Apply it to the `ScrollView` in your tab content.
    public func tabsKitReportsScroll(_ context: TabsKitContentContext) -> some View {
        onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
            context.reportScroll(fingerDelta: old - new)
        }
    }
}

/// The address field's state, for `editingBackground`.
public struct TabsKitAddressEditing {
    /// What is typed so far.
    public var query: String
    /// The tab being edited (nil while there is none).
    public var tab: TabsKitTab?
    /// All open tabs (for "Switch to Tab").
    public var tabs: [TabsKitTab]
    /// Status bar height: start the list below it.
    public var safeTop: CGFloat
    let onGo: @MainActor (String) -> Void
    let onSwitch: @MainActor (TabsKitTab.ID) -> Void

    init(query: String, tab: TabsKitTab?, tabs: [TabsKitTab], safeTop: CGFloat,
         onGo: @escaping @MainActor (String) -> Void, onSwitch: @escaping @MainActor (TabsKitTab.ID) -> Void) {
        self.query = query
        self.tab = tab
        self.tabs = tabs
        self.safeTop = safeTop
        self.onGo = onGo
        self.onSwitch = onSwitch
    }

    /// Navigates the edited tab to `text` and ends editing.
    @MainActor public func go(_ text: String) { onGo(text) }
    /// Switches to another tab and ends editing.
    @MainActor public func switchToTab(_ id: TabsKitTab.ID) { onSwitch(id) }
}

/// The default card: the tab's thumbnail at full screen size (top aligned),
/// or its symbol on the page background before there is one.
public struct TabsKitThumbnailCard: View {
    var tab: TabsKitTab
    var image: UIImage?
    @Environment(\.tabsKitTheme) private var theme

    public init(tab: TabsKitTab, image: UIImage?) {
        self.tab = tab
        self.image = image
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                theme.colors.pageBackground
                if let image {
                    Image(uiImage: image).resizable().interpolation(.medium)
                        .frame(width: geo.size.width, height: geo.size.width * image.size.height / max(1, image.size.width))
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                } else {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(theme.colors.secondaryLabel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
#endif
