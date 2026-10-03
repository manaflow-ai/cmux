public import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// Which permission surface a host view shows.
@MainActor
public enum AppPermissionsSurface {
    /// The install consent sheet.
    case consent(AppConsentModel)
    /// Settings > Apps > <app> > Permissions (the model's selected app).
    case permissions(AppPermissionsModel)
    /// The inline first-use prompt inside the app's surface.
    case firstUse(AppFirstUsePrompt)
    /// Installed Apps (Hide/Unhide, Disable/Enable, Remove).
    case installed(AppInstallsModel)
    /// The "Show Hidden Apps" sheet.
    case hiddenApps(AppInstallsModel)
}

/// Hosts one permission surface (SwiftUI in an NSHostingView). Resolves
/// colors in this view's theme scope and again on every theme or
/// appearance change, and reads the style from `style` (observed).
@MainActor
public final class AppPermissionsHostView: NSView {
    public let surface: AppPermissionsSurface
    private let appearanceState = PermissionsAppearance()
    private let hosting: NSHostingView<PermissionsRoot>

    /// `scrolls` wraps the surface in a scroll view (Settings pane); pass
    /// false to size the view to its content (sheets, prompts, snapshots).
    /// `installedStyle` drives the Installed Apps prototypes (cards when nil).
    public init(surface: AppPermissionsSurface, style: any AppPermissionsStyleSource,
                installedStyle: (any AppInstalledStyleSource)? = nil, scrolls: Bool = true) {
        self.surface = surface
        hosting = NSHostingView(rootView: PermissionsRoot(surface: surface, style: style, installedStyle: installedStyle,
                                                          appearance: appearanceState, scrolls: scrolls))
        super.init(frame: .zero)
        wantsLayer = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        resolveColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The content height at `width` (for a sheet or a snapshot).
    public func fittingHeight(width: CGFloat) -> CGFloat {
        hosting.rootView.measured(width: width)
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() { resolveColors() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = performWithTheme { AppPermissionsColors(tokens: themeTokens) }
        if appearanceState.colors != colors { appearanceState.colors = colors }
    }
}
