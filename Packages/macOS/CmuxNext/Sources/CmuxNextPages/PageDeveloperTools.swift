public import AppKit
import CmuxNextDesign

/// Developer tools for cmux's own pages (an agent chat, Home, Markdown, Settings): the Inspect
/// Element row their right-click menus end with, in either engine. By default it follows the
/// person's `developerTools.appPages` (``CmuxNextDesign/DesignSettings/pageDeveloperTools``) and
/// asks the app's page host to inspect (``PageChromiumHosting/inspectPage(_:)``); with no page host
/// (tests, tools) no page offers the row. A test passes its own closures.
///
/// ```swift
/// let tools = PageDeveloperTools(isEnabled: { true }, inspect: { inspected.append($0) })
/// tools.append(to: menu, for: page)
/// ```
@MainActor
public struct PageDeveloperTools {
    /// The Inspect Element row's identifier: a host that builds its own row (the agent chat's menu)
    /// marks it with this one, and the page adds no second row.
    public static let itemIdentifier = NSUserInterfaceItemIdentifier("cmux.page.inspectElement")

    /// Whether pages offer developer tools now (`developerTools.appPages`), read as each menu opens.
    public var isEnabled: @MainActor () -> Bool
    /// Opens the developer tools of the page shown by `view` (a ``PageWebView`` or a page's own
    /// `WKWebView`) and starts picking an element.
    public var inspect: @MainActor (NSView) -> Void

    /// - Parameters:
    ///   - isEnabled: Whether pages offer developer tools now; the person's setting by default.
    ///   - inspect: Opens the developer tools of a page's view and starts element selection; by
    ///     default the app's page host does (``PageChromiumHosting/inspectPage(_:)``).
    public init(isEnabled: @escaping @MainActor () -> Bool = { DesignSettings.shared.pageDeveloperTools && PageWebView.chromiumHosting != nil },
                inspect: @escaping @MainActor (NSView) -> Void = { PageWebView.chromiumHosting?.inspectPage($0) }) {
        self.isEnabled = isEnabled
        self.inspect = inspect
    }

    /// The row's title, as browsers name it.
    public static var title: String {
        String(localized: "pages.menu.inspectElement", defaultValue: "Inspect Element", bundle: .module)
    }

    /// The Inspect Element row for `view`, or nil while developer tools are off.
    ///
    /// - Parameter view: The page's view the row inspects.
    /// - Returns: A row marked with ``itemIdentifier``.
    public func menuItem(for view: NSView) -> NSMenuItem? {
        guard isEnabled() else { return nil }
        let inspect = inspect
        let item = PageMenuAction.item(Self.title) { [weak view] in
            guard let view else { return }
            inspect(view)
        }
        item.identifier = Self.itemIdentifier
        return item
    }

    /// Ends `menu` with the Inspect Element row for `view`, after a separator when the menu has
    /// rows: nothing while off or when the menu already has the row. WebKit's own Inspect Element
    /// item goes, so the menu has one.
    ///
    /// - Parameters:
    ///   - menu: The page's menu, edited by its host.
    ///   - view: The page's view the row inspects.
    public func append(to menu: NSMenu, for view: NSView) {
        if let webKit = menu.items.firstIndex(where: { $0.identifier?.rawValue == Self.webKitItem }) { menu.removeItem(at: webKit) }
        guard !menu.items.contains(where: { $0.identifier == Self.itemIdentifier }), let item = menuItem(for: view) else { return }
        if menu.items.contains(where: { !$0.isSeparatorItem }), menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) }
        menu.addItem(item)
    }

    /// WebKit's own Inspect Element item.
    static let webKitItem = "WKMenuItemIdentifierInspectElement"
}
