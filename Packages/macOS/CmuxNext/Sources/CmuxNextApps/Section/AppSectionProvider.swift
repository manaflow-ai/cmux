public import AppKit
import CmuxNextDesign

/// App sidebar sections for the sidebar (`SidebarAppSectionProvider`: a
/// title, an NSView and a height per implementation global id
/// `<app id>#<section id>`). One mount per section, rendered from the app
/// supervisor's scene stream (`apps-scene`); the view stays alive while the
/// sidebar shows it. While the supervisor is unreachable the section shows
/// the disconnected reason; while apps cannot run here at all (a daemon with no
/// app host, or apps turned off) it draws nothing (Lawrence 2026-11-12: "get rid
/// of “Needs a newer cmux”"): the sidebar has nothing to offer about it, and the
/// Apps page says why.
@MainActor
public final class AppSectionProvider {
    let client: AppsClient
    /// The App's one presence rule (`AppPresence`); default: the record's own state.
    let isPresented: (String) -> Bool
    private var mounts: [String: (mount: AppMount, view: NSView)] = [:]
    /// `apps.section.look` unless overridden (demo).
    public var lookOverride: AppSectionLook?
    /// Runs when a mounted section's content height may have changed.
    public var onContentChange: (() -> Void)? {
        didSet { widgets?.onContentChange = onContentChange }
    }
    /// The window's widget area (``AppWidgetSection/contribution``), once ``showWidgets(place:)`` ran.
    public private(set) var widgets: AppWidgetSection?

    public init(client: AppsClient, isPresented: ((String) -> Bool)? = nil) {
        self.client = client
        self.isPresented = isPresented ?? { [client] in client.app($0)?.isVisible == true }
    }

    /// The section's title, or nil when no visible app implements it (the
    /// sidebar then shows its "App not installed" placeholder).
    /// Draws the window's widget area of `place` too (the sidebar's); reads its layout now.
    public func showWidgets(place: String) {
        guard widgets == nil else { return }
        widgets = AppWidgetSection(client: client, place: place)
        widgets?.onContentChange = onContentChange
    }

    public func title(for contribution: String) -> String? {
        if contribution == AppWidgetSection.contribution { return widgets?.title }
        if let (app, section) = resolve(contribution) { return section.title?.resolved() ?? client.app(app)?.manifest.name.resolved() ?? app }
        return provisional(contribution).map { $0.app }
    }

    public func makeView(for contribution: String) -> NSView? {
        if contribution == AppWidgetSection.contribution { return widgets?.makeView() }
        if appsCannotRunHere {
            release(contribution)
            return nil
        }
        if let existing = mounts[contribution] {
            // A section mounted before the list landed: drop it once the list says it does not show.
            guard client.isListed, resolve(contribution) == nil else { return existing.view }
            release(contribution)
            return nil
        }
        guard let (app, section) = resolve(contribution) ?? provisional(contribution) else { return nil }
        let mount = client.mount(app, implementation: section, surface: "sidebarSection")
        let look = lookOverride ?? AppsTunables.sectionLook.value
        // AppKit: the scene draws natively, so a custom section reads as the built-in rows.
        let scene = AppSceneHostingView(model: mount.model, bundleDirectory: mount.bundleDirectory)
        let view = AppSectionView(scene: scene, look: look)
        scene.onContentSizeChange = { [weak self] in self?.onContentChange?() }
        mounts[contribution] = (mount, view)
        return view
    }

    public func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        if contribution == AppWidgetSection.contribution { return widgets?.preferredHeight(width: width) ?? 0 }
        guard let view = mounts[contribution]?.view as? AppSectionView else { return 0 }
        return view.preferredHeight(width: width)
    }

    /// Apps cannot run on this daemon (no app host beside it) or a policy turned them off: no
    /// connect or retry changes that, so a section is not worth a card.
    private var appsCannotRunHere: Bool {
        guard let reason = client.unavailableReason else { return false }
        return !reason.daemonUnreachable
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
        guard let section = app.manifest.sceneSection(parts[1]) else { return nil }
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

    /// Unmounts every section and widget (the window's sidebar went away or replaced its sections).
    /// The widget area is not released with its section: it keeps its tiles while they are placed.
    public func releaseAll() {
        widgets?.releaseAll()
        for contribution in Array(mounts.keys) { release(contribution) }
    }
}
