#if os(iOS)
import SwiftUI
import UIKit

/// Holds a ``PagedList``'s collection view with what the screen pins to it (verify/paged-list.md,
/// "Bottom accessory"):
///
/// - a bottom accessory, any SwiftUI view (a composer, a reply bar, a toolbar), whose bottom rides
///   `keyboardLayoutGuide` (8 pt gap none: the accessory draws its own padding), so UIKit moves it
///   in the keyboard's own animation and with the finger in an interactive dismissal. The list's
///   bottom inset is the accessory's top, set in the same layout pass, and the rows answer it as the
///   list's ``PagedListBottomPinning`` says;
/// - a newest-rows indicator (the screen's own look) at the list's newest end: above the bottom
///   edge of an `.up` list, under the top edge of a `.down` one (never over the older edge's
///   spinner or Try Again);
/// - the first page's states (loading, failed, empty) over the rows, so an accessory stays put
///   (and keeps its focus) while they show.
///
/// The same pattern as the agent chat's dock (`ChatTranscriptController`), as a reusable piece.
@MainActor
final class PagedListHostController: UIViewController {
    let list: PagedListCollectionView
    private let newest: PagedListNewestState
    private let accessoryHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let dock = PagedListDockView()
    private var indicatorHost: UIHostingController<AnyView>?
    private var indicatorBottom: NSLayoutConstraint?
    private var indicatorTop: NSLayoutConstraint?
    private let overlayHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var keyboardPin: NSLayoutConstraint?
    private var hasAccessory = false
    private var followsKeyboard = true
    private(set) var accessoryHeight: CGFloat = 0
    /// The accessory's host is tall and transparent: the accessory grows inside it on its own
    /// (SwiftUI) animation, and UIKit only ever moves the host.
    static let dockHostHeight: CGFloat = 640

    init(list: PagedListCollectionView, newest: PagedListNewestState) {
        self.list = list
        self.newest = newest
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // Docked keyboards only (as the agent chat's dock: with `followsUndockedKeyboard` the guide
        // never left the bottom edge on iOS 27).
        view.keyboardLayoutGuide.followsUndockedKeyboard = false
        view.keyboardLayoutGuide.usesBottomSafeArea = false

        list.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: view.topAnchor),
            list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        for host in [overlayHost, accessoryHost] {
            addChild(host)
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
        }
        overlayHost.view.isHidden = true
        view.addSubview(overlayHost.view)

        dock.translatesAutoresizingMaskIntoConstraints = false
        accessoryHost.view.translatesAutoresizingMaskIntoConstraints = false
        dock.addSubview(accessoryHost.view)
        view.addSubview(dock)
        dock.isHidden = true
        let rest = dock.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        rest.priority = .defaultLow
        let pin = dock.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor)
        keyboardPin = pin
        NSLayoutConstraint.activate([
            accessoryHost.view.topAnchor.constraint(equalTo: dock.topAnchor),
            accessoryHost.view.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
            accessoryHost.view.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
            accessoryHost.view.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
            dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dock.heightAnchor.constraint(equalToConstant: Self.dockHostHeight),
            dock.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
            rest,
            pin,
        ])
        for host in [overlayHost, accessoryHost] { host.didMove(toParent: self) }
    }

    /// A keyboard frame worth following: as wide as the view and touching its bottom (a docked
    /// software keyboard, or the guide at rest). A hardware keyboard's guide can report a 0-wide
    /// frame near the top of the screen; the accessory rests then.
    private var keyboardPinApplies: Bool {
        let frame = view.keyboardLayoutGuide.layoutFrame
        return followsKeyboard && frame.width >= view.bounds.width - 1 && frame.maxY >= view.bounds.maxY - 1
    }

    // MARK: What the screen pins

    func setAccessory(_ content: AnyView?, background: AnyShapeStyle? = nil, followsKeyboard: Bool) {
        self.followsKeyboard = followsKeyboard
        guard let content else {
            if hasAccessory {
                hasAccessory = false
                dock.isHidden = true
                accessoryHost.rootView = AnyView(EmptyView())
                accessoryChanged(height: 0)
            }
            return
        }
        hasAccessory = true
        dock.isHidden = false
        accessoryHost.rootView = AnyView(PagedListAccessoryRoot(content: content, background: background) { [weak self] height in
            self?.accessoryChanged(height: height)
        })
    }

    func setIndicator(_ make: ((PagedListNewest) -> AnyView)?, direction: PagedListDirection) {
        guard let make else {
            indicatorHost?.willMove(toParent: nil)
            indicatorHost?.view.removeFromSuperview()
            indicatorHost?.removeFromParent()
            indicatorHost = nil
            return
        }
        let root = AnyView(PagedListIndicatorRoot(state: newest, content: make))
        if let indicatorHost {
            indicatorHost.rootView = root
            placeIndicator(atTop: direction == .down)
            return
        }
        let host = UIHostingController(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.insertSubview(host.view, belowSubview: dock)
        host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        indicatorBottom = host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        indicatorTop = host.view.topAnchor.constraint(equalTo: view.topAnchor)
        host.didMove(toParent: self)
        indicatorHost = host
        placeIndicator(atTop: direction == .down)
    }

    /// The indicator sits at the newest end: the top of a `.down` list, the bottom of an `.up` one.
    private func placeIndicator(atTop: Bool) {
        guard indicatorTop?.isActive != atTop || indicatorBottom?.isActive != !atTop else { return }
        indicatorTop?.isActive = atTop
        indicatorBottom?.isActive = !atTop
        view.setNeedsLayout()
    }

    /// The first page's state over the rows (nil: the rows show).
    func setOverlay(_ content: AnyView?) {
        overlayHost.view.isHidden = content == nil
        overlayHost.rootView = content ?? AnyView(EmptyView())
        view.setNeedsLayout()
    }

    private func accessoryChanged(height: CGFloat) {
        guard abs(height - accessoryHeight) > 0.25 else { return }
        accessoryHeight = height
        dock.interactiveHeight = height
        view.setNeedsLayout()
        // The rows answer the new edge in this frame (the accessory grows on SwiftUI's animation).
        UIView.performWithoutAnimation { view.layoutIfNeeded() }
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let pin = keyboardPin, pin.isActive != keyboardPinApplies {
            pin.isActive = keyboardPinApplies
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return
        }
        // The list's bottom edge is the accessory's top: the keyboard (or the resting place) sets
        // the accessory's bottom, the accessory its height.
        let inset: CGFloat = hasAccessory
            ? max(0, view.bounds.maxY - (dock.frame.maxY - accessoryHeight) - list.safeAreaInsets.bottom)
            : 0
        if abs(list.contentInset.bottom - inset) > 0.25 {
            list.contentInset.bottom = inset
            list.verticalScrollIndicatorInsets.bottom = inset
        }
        // As in Messages, a drag of the rows takes the keyboard once the finger reaches the accessory.
        if hasAccessory, abs(view.keyboardLayoutGuide.keyboardDismissPadding - accessoryHeight) > 0.5 {
            view.keyboardLayoutGuide.keyboardDismissPadding = accessoryHeight
        }
        let adjusted = list.adjustedContentInset
        indicatorBottom?.constant = -(adjusted.bottom + 8)
        indicatorTop?.constant = adjusted.top + 8
        if !overlayHost.view.isHidden {
            overlayHost.view.frame = CGRect(x: 0, y: adjusted.top, width: view.bounds.width,
                                            height: max(0, view.bounds.height - adjusted.top - adjusted.bottom))
        }
    }
}

/// Takes touches only in its bottom `interactiveHeight` (the accessory); the empty space above lets
/// them through to the rows. (SwiftUI handles its gestures in the hosting view itself, so the hit
/// view cannot tell.)
final class PagedListDockView: UIView {
    var interactiveHeight: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        point.y >= bounds.height - interactiveHeight && super.point(inside: point, with: event)
    }
}

/// The accessory at the bottom of its tall host, reporting its height as laid out.
private struct PagedListAccessoryRoot: View {
    let content: AnyView
    let background: AnyShapeStyle?
    let measured: (CGFloat) -> Void
    /// How far the background reaches below the accessory: past the home indicator and any
    /// keyboard (the hosting view does not clip, and touches there go to the keyboard).
    static let reach: CGFloat = 1200

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
                .background(alignment: .top) {
                    if let background {
                        Rectangle().fill(background).padding(.bottom, -Self.reach)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// The screen's indicator, redrawn as the list's newest-rows state changes.
private struct PagedListIndicatorRoot: View {
    let state: PagedListNewestState
    let content: (PagedListNewest) -> AnyView

    var body: some View {
        content(state.value)
    }
}

/// A ready-made newest-rows indicator for screens that want one (``PagedList/pagedNewestIndicator(_:)``):
/// a round button with a chevron toward the newest end and the count of rows that arrived. Shown
/// while the reader is away from the newest end.
public struct PagedListNewestPill: View {
    let newest: PagedListNewest
    let direction: PagedListDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ newest: PagedListNewest, direction: PagedListDirection) {
        self.newest = newest
        self.direction = direction
    }

    public var body: some View {
        let theme = CmuxMobileTheme.standard
        ZStack {
            if newest.isAway {
                Button(action: newest.jump) {
                    Image(systemName: direction == .up ? "chevron.down" : "chevron.up")
                        .font(theme.type.rowTitle.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if newest.unseen > 0 {
                                Text(newest.unseen > 99 ? "99+" : "\(newest.unseen)")
                                    .font(theme.type.meta.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(theme.colors.accent.color, in: Capsule())
                                    .offset(x: 6, y: -6)
                            }
                        }
                }
                .buttonStyle(.cmuxPressFill)
                .accessibilityLabel(Text(newest.unseen > 0 ? "\(newest.unseen) new" : "Newest"))
                .accessibilityIdentifier("pagedList.newest")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(8)
        .animation(reduceMotion ? nil : CmuxMobileTheme.standard.motion.snappy.animation, value: newest.isAway)
    }
}
#endif
