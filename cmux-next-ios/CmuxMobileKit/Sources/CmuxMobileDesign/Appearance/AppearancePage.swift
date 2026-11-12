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

#if os(iOS)
/// The surface a selected row takes (Leo, 2026-11-10: a selected tab or row
/// is the foreground, "how folder tabs look"; never a grey pill): the content
/// it opens. That is the page color (`bg`), or over a backdrop picture the
/// backdrop itself, laid out in screen coordinates so the row reads as the
/// same page the card shows. The card's own hairline and shadow set it apart
/// where the chrome around it shares the page's color (the neutral look).
public struct CmuxMobileSelectedSurface<S: InsettableShape>: View {
    private let shape: S
    private let appearance = CmuxMobileAppearance.shared

    public init(_ shape: S) {
        self.shape = shape
    }

    public var body: some View {
        let metrics = CmuxMobileTheme.standard.metrics
        surface
            .clipShape(shape)
            .overlay { shape.strokeBorder(CmuxMobileTheme.standard.colors.cardStroke.color, lineWidth: metrics.cardStrokeWidth) }
            .shadow(color: CmuxMobileTheme.standard.colors.scrim.color.opacity(Double(metrics.cardShadowOpacity)),
                    radius: metrics.cardShadowRadius / 2, x: metrics.cardShadowOffset.width / 2)
    }

    @ViewBuilder private var surface: some View {
        if appearance.backdrop != nil {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                let screen = Self.screenSize ?? proxy.size
                CmuxMobileBackdrop()
                    .frame(width: screen.width, height: screen.height)
                    .offset(x: -frame.minX, y: -frame.minY)
            }
        } else {
            CmuxMobileTheme.standard.colors.bg.color
        }
    }

    /// The window's size: the page backdrop under the sidebar fills it.
    @MainActor private static var screenSize: CGSize? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first
    }
}
#endif
