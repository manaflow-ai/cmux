public import AppKit
import CmuxNextDesign
import SwiftUI

/// App sidebar sections for the sidebar (`SidebarAppSectionProvider`: a
/// title, an NSView and a height per implementation global id
/// `<app id>#<section id>`). One mount per section, rendered from the app
/// supervisor's scene stream (`apps-scene`); the view stays alive while the
/// sidebar shows it. While the supervisor is unreachable the section shows
/// the disconnected reason.
@MainActor
public final class AppSectionProvider {
    let client: AppsClient
    /// The App's one presence rule (`AppPresence`); default: the record's own state.
    let isPresented: (String) -> Bool
    private var mounts: [String: (mount: AppMount, view: NSView)] = [:]
    /// `apps.section.look` unless overridden (demo).
    public var lookOverride: AppSectionLook?
    /// Runs when a mounted section's content height may have changed.
    public var onContentChange: (() -> Void)?

    public init(client: AppsClient, isPresented: ((String) -> Bool)? = nil) {
        self.client = client
        self.isPresented = isPresented ?? { [client] in client.app($0)?.isVisible == true }
    }

    /// The section's title, or nil when no visible app implements it (the
    /// sidebar then shows its "App not installed" placeholder).
    public func title(for contribution: String) -> String? {
        if let (app, section) = resolve(contribution) { return section.title?.resolved() ?? client.app(app)?.manifest.name.resolved() ?? app }
        return provisional(contribution).map { $0.app }
    }

    public func makeView(for contribution: String) -> NSView? {
        if let existing = mounts[contribution] {
            // A section mounted before the list landed: drop it once the list says it does not show.
            guard client.isListed, resolve(contribution) == nil else { return existing.view }
            release(contribution)
            return nil
        }
        guard let (app, section) = resolve(contribution) ?? provisional(contribution) else { return nil }
        let mount = client.mount(app, implementation: section, surface: "sidebarSection")
        let look = lookOverride ?? AppsTunables.sectionLook.value
        let name = client.app(app)?.manifest
        // The sidebar's section header row draws the title and owns collapse.
        let root = AppSectionFrame(look: look, title: section.title?.resolved() ?? name?.name.resolved() ?? app, symbol: section.symbol,
                                   icon: name?.icon, bundleDirectory: mount.bundleDirectory, showsHeader: false) {
            AppSceneView(model: mount.model, bundleDirectory: mount.bundleDirectory)
        }
        let view = AppSectionHostingView(rootView: root)
        view.onSizeChange = { [weak self] in self?.onContentChange?() }
        mounts[contribution] = (mount, view)
        return view
    }

    public func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        guard let view = mounts[contribution]?.view as? AppSectionHostingView else { return 0 }
        return view.preferredHeight(width: width)
    }

    /// Unmounts a section the sidebar no longer shows (the supervisor stops
    /// the app host when nothing else shows that app).
    public func release(_ contribution: String) {
        guard let entry = mounts.removeValue(forKey: contribution) else { return }
        client.unmount(entry.mount)
    }

    /// `<app>#<section>`: the section with that id; a manifest v2 app has one
    /// section (its id is the interface name), so a layout saved with a v1
    /// contribution id still finds it.
    private func resolve(_ contribution: String) -> (app: String, section: AppImplementation)? {
        let parts = contribution.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, isPresented(parts[0]), let app = client.app(parts[0]) else { return nil }
        let sections = app.manifest.sections.filter(\.hasScene)
        guard let section = sections.first(where: { $0.id == parts[1] }) ?? (sections.count == 1 ? sections.first : nil) else { return nil }
        return (app.id, section)
    }

    /// Before the supervisor's list (an older daemon, not connected yet, turned
    /// off): the section mounts anyway, so it shows why it is empty instead of
    /// "not installed", and renders once the supervisor answers.
    private func provisional(_ contribution: String) -> (app: String, section: AppImplementation)? {
        guard !client.isListed else { return nil }
        let parts = contribution.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], AppImplementation(interface: AppImplementation.section, id: parts[1]))
    }

    /// Unmounts every section (the window's sidebar went away or replaced its sections).
    public func releaseAll() {
        for contribution in Array(mounts.keys) { release(contribution) }
    }
}

/// Hosts an `AppSectionFrame` with theme-resolved colors and measures it.
final class AppSectionHostingView: NSHostingView<AnyView> {
    private let sceneAppearance = AppSceneAppearance()
    private let measurer: NSHostingController<AnyView>
    /// Runs when SwiftUI changes the content size (new scene content).
    var onSizeChange: (() -> Void)?

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

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        ceil(measurer.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
