public import AppKit
import CmuxNextDesign
import SwiftUI

/// App sidebar sections for the sidebar (the shape the sections lead
/// agreed for `SidebarAppSectionProvider`: a title, an NSView and a height
/// per contribution global id `<app id>#<section id>`). The App conforms
/// it to the sidebar protocol once `SectionContent.app` lands; until then
/// it is unused (app-platform.md, step 7 TODO). One mount per contribution;
/// the view stays alive while the sidebar shows it.
@MainActor
public final class AppSectionProvider {
    let registry: AppRegistry
    let host: AppHost
    private var mounts: [String: (mount: AppMount, view: NSView)] = [:]
    /// `apps.section.look` unless overridden (demo).
    public var lookOverride: AppSectionLook?

    public init(registry: AppRegistry, host: AppHost) {
        self.registry = registry
        self.host = host
    }

    /// The section's title, or nil when no active app contributes it (the
    /// sidebar then shows its "App not installed" placeholder).
    public func title(for contribution: String) -> String? {
        resolve(contribution).map { $1.title?.resolved() ?? $0.manifest.name.resolved() }
    }

    public func makeView(for contribution: String) -> NSView? {
        if let existing = mounts[contribution] { return existing.view }
        guard let (app, section) = resolve(contribution) else { return nil }
        let mount = host.mount(app.manifest, directory: app.bundle.directory, contribution: section, surface: "sidebarSection")
        let look = lookOverride ?? AppsTunables.sectionLook.value
        let root = AppSectionFrame(look: look, title: section.title?.resolved() ?? app.manifest.name.resolved(), symbol: section.symbol,
                                   icon: app.manifest.icon, bundleDirectory: app.bundle.directory) {
            AppSceneView(model: mount.model, bundleDirectory: mount.bundleDirectory)
        }
        let view = AppSectionHostingView(rootView: root)
        mounts[contribution] = (mount, view)
        return view
    }

    public func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        guard let view = mounts[contribution]?.view as? AppSectionHostingView else { return 0 }
        return view.preferredHeight(width: width)
    }

    /// Unmounts a section the sidebar no longer shows (its engine stops
    /// when nothing else shows that app).
    public func release(_ contribution: String) {
        guard let entry = mounts.removeValue(forKey: contribution) else { return }
        host.unmount(entry.mount)
    }

    private func resolve(_ contribution: String) -> (InstalledApp, AppContribution)? {
        let parts = contribution.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, let app = registry.app(parts[0]), app.isActive,
              let section = app.manifest.contributes.of(.sidebarSection).first(where: { $0.id == parts[1] }) else { return nil }
        return (app, section)
    }
}

/// Hosts an `AppSectionFrame` with theme-resolved colors and measures it.
final class AppSectionHostingView: NSHostingView<AnyView> {
    private let sceneAppearance = AppSceneAppearance()
    private let measurer: NSHostingController<AnyView>

    init<Content: View>(rootView content: Content) {
        let appearance = sceneAppearance
        let root = AnyView(AppSceneThemedRoot(appearance: appearance) { content })
        measurer = NSHostingController(rootView: root)
        super.init(rootView: root)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sceneAppearance.update(from: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sceneAppearance.update(from: self)
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        ceil(measurer.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
