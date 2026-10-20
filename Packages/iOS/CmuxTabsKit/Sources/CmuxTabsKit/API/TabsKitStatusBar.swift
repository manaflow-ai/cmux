#if os(iOS)
import SwiftUI
import UIKit

extension TabsKitStatusBarStyle {
    /// The style for content whose top edge has `color` (relative luminance).
    public init(over color: UIColor) {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.resolvedColor(with: .current).getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        self = luminance > 0.4 ? .darkContent : .lightContent
    }

    var uiStyle: UIStatusBarStyle {
        switch self {
        case .darkContent: .darkContent
        case .lightContent: .lightContent
        }
    }
}

/// Preference the `TabsView` sets for the active tab; the first non-nil
/// value in the tree wins.
struct TabsKitStatusBarStylePreferenceKey: PreferenceKey {
    static let defaultValue: TabsKitStatusBarStyle? = nil
    static func reduce(value: inout TabsKitStatusBarStyle?, nextValue: () -> TabsKitStatusBarStyle?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Asks the host for a status bar style while this view is shown (nil:
    /// follow the appearance). `TabsView` sets it from the active tab.
    public func tabsKitStatusBarStyle(_ style: TabsKitStatusBarStyle?) -> some View {
        preference(key: TabsKitStatusBarStylePreferenceKey.self, value: style)
    }

    /// Host side: observes the status bar style requested below this view.
    /// `TabsKitHostingController` applies it for you.
    public func onTabsKitStatusBarStyleChange(_ action: @escaping @MainActor (TabsKitStatusBarStyle?) -> Void) -> some View {
        onPreferenceChange(TabsKitStatusBarStylePreferenceKey.self) { value in
            MainActor.assumeIsolated { action(value) }
        }
    }
}

/// A hosting controller that applies the status bar style the tabs ask
/// for. Use it as (or under) the window's root view controller; SwiftUI's
/// own root controller does not read the preference.
public final class TabsKitHostingController<Content: View>: UIHostingController<AnyView> {
    private var requested: TabsKitStatusBarStyle?

    public init(rootView: Content) {
        let relay = StyleRelay()
        super.init(rootView: AnyView(rootView.onTabsKitStatusBarStyleChange { relay.apply($0) }))
        relay.controller = self
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("TabsKitHostingController is created in code")
    }

    override public var preferredStatusBarStyle: UIStatusBarStyle { requested?.uiStyle ?? .default }

    fileprivate func apply(_ style: TabsKitStatusBarStyle?) {
        guard style != requested else { return }
        requested = style
        setNeedsStatusBarAppearanceUpdate()
    }

    @MainActor
    private final class StyleRelay {
        weak var controller: TabsKitHostingController?
        func apply(_ style: TabsKitStatusBarStyle?) { controller?.apply(style) }
    }
}
#endif
