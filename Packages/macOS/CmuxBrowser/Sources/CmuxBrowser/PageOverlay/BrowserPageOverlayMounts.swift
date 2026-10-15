public import SwiftUI

extension View {
    /// Marks this view as an occluding page overlay (a bar or card that takes
    /// the keyboard: find bar, permission bar, crash page). Over a Chromium
    /// page the page leaves a hole where it shows; over a WebKit page, or
    /// with a nil coordinator, nothing changes.
    ///
    /// A rounded card passes its `cornerRadius`: the hole is notched so the
    /// page shows in the card's corners (design spec §0.9).
    public func browserPageOccluding(
        _ coordinator: BrowserPageOverlayCoordinator?,
        id: String,
        cornerRadius: CGFloat = 0
    ) -> some View {
        background(BrowserPageOverlayAnchor(coordinator: coordinator, id: id, cornerRadius: cornerRadius,
                                            floatingContent: nil, floatingBlurRadius: nil))
    }

    /// The background of an occluding card: material and a soft shadow over
    /// a WebKit page; over a Chromium page, where the card sits in a hole of
    /// the page (material would blur cmux's own views and the shadow would be
    /// clipped), an opaque `fill` with a 0.5 pt separator stroke (design spec
    /// §0.9). Pair it with `browserPageOccluding(_:id:cornerRadius:)`.
    public func browserPageOverlayCard(
        _ coordinator: BrowserPageOverlayCoordinator?,
        cornerRadius: CGFloat,
        fill: Color
    ) -> some View {
        modifier(BrowserPageOverlayCardBackground(coordinator: coordinator, cornerRadius: cornerRadius, fill: fill))
    }
}

/// See `View.browserPageOverlayCard(_:cornerRadius:fill:)`.
struct BrowserPageOverlayCardBackground: ViewModifier {
    let coordinator: BrowserPageOverlayCoordinator?
    let cornerRadius: CGFloat
    let fill: Color

    func body(content: Content) -> some View {
        if let coordinator {
            ObservedCard(coordinator: coordinator, cornerRadius: cornerRadius, fill: fill, content: content)
        } else {
            Self.inViewCard(content, cornerRadius: cornerRadius)
        }
    }

    static func inViewCard(_ content: Content, cornerRadius: CGFloat) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.11), radius: 6, y: 2)
    }

    private struct ObservedCard: View {
        @ObservedObject var coordinator: BrowserPageOverlayCoordinator
        let cornerRadius: CGFloat
        let fill: Color
        let content: Content

        var body: some View {
            if coordinator.overlaysSitInPageHoles {
                content
                    .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            } else {
                BrowserPageOverlayCardBackground.inViewCard(content, cornerRadius: cornerRadius)
            }
        }
    }
}

/// A floating page overlay (a rounded card over the live page, such as the
/// engine notice). Over a Chromium page it draws in a non-activating child
/// panel above the page, sized and placed where it would lay out here; over
/// a WebKit page it renders in place.
///
/// In a panel the content gets its own hosting view: it takes the window's
/// appearance, not this view's SwiftUI environment, so pass anything it
/// reads (colors, fonts, models) explicitly.
///
/// A translucent card passes `blurCornerRadius`: in a panel it then sits on
/// an `NSVisualEffectView` with `.behindWindow` blending clipped to that
/// radius, so it blurs the Chromium page under it (SwiftUI material inside
/// the panel would only blur the panel itself; design spec §0.9). Its own
/// content should then leave its background clear in a panel.
public struct BrowserPageFloatingOverlay<Content: View>: View {
    @ObservedObject private var coordinator: BrowserPageOverlayCoordinator
    private let id: String
    private let blurCornerRadius: CGFloat?
    private let content: Content

    public init(
        coordinator: BrowserPageOverlayCoordinator,
        id: String,
        blurCornerRadius: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.coordinator = coordinator
        self.id = id
        self.blurCornerRadius = blurCornerRadius
        self.content = content()
    }

    public var body: some View {
        if coordinator.hostsFloatingOverlaysInPanels {
            // Lays out here (hidden) so the panel gets the same frame.
            content
                .hidden()
                .background(BrowserPageOverlayAnchor(coordinator: coordinator, id: id, cornerRadius: 0,
                                                     floatingContent: AnyView(content),
                                                     floatingBlurRadius: blurCornerRadius))
        } else {
            content
        }
    }
}

/// The invisible view that reports an overlay's frame to the coordinator.
struct BrowserPageOverlayAnchor: NSViewRepresentable {
    let coordinator: BrowserPageOverlayCoordinator?
    let id: String
    /// Corner radius of an occluding card (notched hole).
    let cornerRadius: CGFloat
    /// Set for a floating overlay: what its panel shows.
    let floatingContent: AnyView?
    /// Set for a floating overlay that blurs the page behind its panel.
    let floatingBlurRadius: CGFloat?

    func makeNSView(context: Context) -> BrowserPageOverlayAnchorView {
        let view = BrowserPageOverlayAnchorView()
        view.configure(coordinator: coordinator, id: id, cornerRadius: cornerRadius,
                       floatingContent: floatingContent, floatingBlurRadius: floatingBlurRadius)
        return view
    }

    func updateNSView(_ view: BrowserPageOverlayAnchorView, context: Context) {
        view.configure(coordinator: coordinator, id: id, cornerRadius: cornerRadius,
                       floatingContent: floatingContent, floatingBlurRadius: floatingBlurRadius)
    }

    static func dismantleNSView(_ view: BrowserPageOverlayAnchorView, coordinator: ()) {
        view.unregister()
    }
}

/// Registers with the coordinator while in a window and asks it to sync on
/// every frame, window and visibility change.
final class BrowserPageOverlayAnchorView: NSView {
    private weak var coordinator: BrowserPageOverlayCoordinator?
    private var id = ""
    private var hostingView: NSHostingView<AnyView>?
    /// What the floating panel shows: the hosting view, or a behind-window
    /// blur holding it.
    private var floatingRoot: NSView?
    private var cornerRadius: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        coordinator: BrowserPageOverlayCoordinator?,
        id: String,
        cornerRadius: CGFloat,
        floatingContent: AnyView?,
        floatingBlurRadius: CGFloat?
    ) {
        if self.coordinator !== coordinator || self.id != id { unregister() }
        self.coordinator = coordinator
        self.id = id
        self.cornerRadius = cornerRadius
        if let floatingContent {
            if let hostingView {
                hostingView.rootView = floatingContent
            } else {
                hostingView = NSHostingView(rootView: floatingContent)
            }
            floatingRoot = Self.floatingRoot(hosting: hostingView!, existing: floatingRoot, blurRadius: floatingBlurRadius)
        } else {
            hostingView = nil
            floatingRoot = nil
        }
        register()
    }

    /// The hosting view alone, or inside an `NSVisualEffectView` that blurs
    /// what is behind the panel window (the Chromium page), clipped to
    /// `blurRadius`.
    private static func floatingRoot(hosting: NSView, existing: NSView?, blurRadius: CGFloat?) -> NSView {
        guard let blurRadius else { return hosting }
        let effect = (existing as? NSVisualEffectView) ?? NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = blurRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        if hosting.superview !== effect {
            hosting.removeFromSuperview()
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
        }
        return effect
    }

    func unregister() {
        guard let coordinator else { return }
        coordinator.unregisterOccluding(id: id)
        coordinator.unregisterFloating(id: id)
    }

    private func register() {
        guard let coordinator else { return }
        guard window != nil else {
            unregister()
            return
        }
        if let floatingRoot {
            coordinator.registerFloating(self, id: id, content: floatingRoot)
        } else {
            coordinator.registerOccluding(self, id: id, cornerRadius: cornerRadius)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        register()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        coordinator?.update()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        coordinator?.update()
    }

    override func viewDidHide() {
        super.viewDidHide()
        coordinator?.update()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        coordinator?.update()
    }
}
