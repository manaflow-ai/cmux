public import AppKit
public import CmuxNextDesign
import SwiftUI

/// Which server surface a host view shows. A nil style follows the Debug
/// Settings switch; a value pins one prototype (demos and screenshots).
public enum ServerSurface: Equatable {
    case panel(ServerPanelStyle?)
    case pairing(ServerPairingStyle?)
    case health(ServerHealthStyle?)
    /// The approving device's sheet (enter code, check facts, Approve).
    case approver
}

/// Hosts one server surface on an overlay material: Liquid Glass on macOS
/// 26 and later, a tinted blur before, an opaque Ghostty-derived fill under
/// Reduce Transparency. Resolves the colors in this view's theme scope and
/// again on every theme change.
@MainActor
public final class ServerHostView: NSView {
    public let model: ServerModel
    public let surface: ServerSurface
    /// Called when the approver sheet closes (Cancel or approved).
    public var onDismiss: (() -> Void)? {
        didSet { dismissBox.action = onDismiss }
    }

    private let appearanceState = ServerAppearance()
    private let dismissBox = DismissBox()
    private let backdrop: OverlaySurfaceView
    /// A theme-colored wash over the glass, so secondary text keeps its
    /// contrast over any wallpaper.
    private let wash = NSView()
    private let hosting: NSHostingView<ServerRoot>

    /// `material` pins the backdrop (tests, screenshots); nil follows this Mac.
    public init(model: ServerModel, surface: ServerSurface, material: OverlayMaterial? = nil) {
        self.model = model
        self.surface = surface
        backdrop = OverlaySurfaceView(material: material)
        hosting = NSHostingView(rootView: ServerRoot(model: model, surface: surface, appearance: appearanceState, dismiss: dismissBox))
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.cornerRadius = ServerMetrics.cornerRadius
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        wash.wantsLayer = true
        wash.frame = bounds
        wash.autoresizingMask = [.width, .height]
        wash.layer?.cornerRadius = ServerMetrics.cornerRadius
        wash.layer?.cornerCurve = .continuous
        addSubview(wash)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = [.intrinsicContentSize]
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The size the surface wants (a menubar popover sizes to it).
    public var preferredSize: NSSize { hosting.fittingSize }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        resolveColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = performWithTheme {
            let base = Palette.windowBackground.usingColorSpace(.sRGB) ?? Palette.windowBackground
            wash.layer?.backgroundColor = base.withAlphaComponent(backdrop.material == .opaque ? 0 : Self.washAlpha).cgColor
            return ServerColors(
                primary: Self.color(Palette.textPrimary), secondary: Self.color(Palette.textSecondary),
                tertiary: Self.color(Palette.textTertiary), hover: Self.color(Palette.hoverFill),
                selection: Self.color(Palette.selectionFill), separator: Self.color(Palette.separator),
                warning: Self.color(Palette.attention), critical: Self.color(Palette.danger),
                ok: Self.color(Palette.success), onPrimary: Self.color(Palette.textOnPrimary))
        }
        if appearanceState.colors != colors { appearanceState.colors = colors }
        backdrop.applyTheme()
    }

    private static let washAlpha: CGFloat = 0.78

    /// A static color: dynamic ones would re-resolve outside this view's theme scope.
    private static func color(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}
