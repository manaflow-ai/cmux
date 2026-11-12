#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// A page of a navigation stack (a tab's root or a pushed screen). Its
    /// container's background is the page color (`bg`): the system color in
    /// the neutral look, the theme's color with a theme, and clear over a
    /// backdrop picture. Over a picture the system containers between the
    /// page and the backdrop (the navigation and tab controllers' views) are
    /// cleared too, so the one backdrop under the card shows through every
    /// screen, as the Mac's window background shows through its panes.
    /// Without a picture nothing is cleared: the page looks as it always did.
    public func cmuxMobilePage() -> some View {
        modifier(CmuxMobilePageModifier())
    }
}

private struct CmuxMobilePageModifier: ViewModifier {
    private let appearance = CmuxMobileAppearance.shared

    func body(content: Content) -> some View {
        content
            .containerBackground(for: .navigation) { CmuxMobileTheme.standard.colors.bg.color }
            .background {
                PageContainers(active: appearance.backdrop != nil)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// Clears the opaque system containers from a page up to the backdrop that
/// draws under it (the nearest ancestor holding a ``CmuxMobileBackdropUIView``),
/// and puts them back when the backdrop goes. Nothing is cleared when no
/// backdrop is found above the page (a sheet keeps its own opaque page).
private struct PageContainers: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> PageContainersView { PageContainersView() }

    func updateUIView(_ view: PageContainersView, context: Context) {
        view.active = active
        view.sweep()
    }
}

@MainActor
final class PageContainersView: UIView {
    var active = false

    /// Every view cleared, with the color it had (weak keys: a dropped page lets go).
    private static let cleared = NSMapTable<UIView, UIColor>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // A theme change (or Light/Dark) can make SwiftUI repaint a container: clear it again.
        registerForTraitChanges([CmuxMobileAppearanceRevisionTrait.self, UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.sweep()
        }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sweep()
    }

    func sweep() {
        guard window != nil else { return }
        guard active else {
            Self.restoreAll()
            return
        }
        var chain: [UIView] = []
        var view = superview
        while let current = view {
            if current.subviews.contains(where: { $0 is CmuxMobileBackdropUIView }) {
                for container in chain { Self.clear(container) }
                return
            }
            chain.append(current)
            view = current.superview
        }
    }

    private static func clear(_ view: UIView) {
        guard let color = view.backgroundColor, color.cgColor.alpha > 0 else { return }
        if cleared.object(forKey: view) == nil { cleared.setObject(color, forKey: view) }
        view.backgroundColor = .clear
    }

    private static func restoreAll() {
        guard cleared.count > 0, let keys = cleared.keyEnumerator().allObjects as? [UIView] else { return }
        for view in keys {
            if let color = cleared.object(forKey: view), view.backgroundColor == .clear { view.backgroundColor = color }
        }
        cleared.removeAllObjects()
    }
}
#endif
