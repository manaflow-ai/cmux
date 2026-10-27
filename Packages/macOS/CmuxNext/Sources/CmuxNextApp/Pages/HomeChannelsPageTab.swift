import AppKit
import CmuxNextHibernation
import CmuxNextPages

/// The channels Home as an internal page tab, one per window: a pane tab, so it sits next to the
/// native Home (and any other tab) in a split. Opened by "Open Channels" (palette, File menu,
/// `cmux home channels`).
@MainActor
final class HomeChannelsPageTab: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .homeChannels }
    var title: String { HomeChannelsStrings.title }
    var symbol: String { "number" }

    static func make(_ services: AppServices) -> HomeChannelsPageTab { HomeChannelsPageTab(services: services) }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services, let view = PageFactory(services: services).homeChannelsWebPage() else { return NSView() }
        view.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        pages.removeValue(forKey: key)?.close()
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden, unless a composer holds unsent input (``keepReasons(for:)``).
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// A composer's unsent text or files live only in the page: while the page holds them, it
    /// stays (``keepReasons(of:)``; Chrome's `kFormInteractions`, discard_eligibility_policy.cc).
    func keepReasons(for key: String) -> [CannotDiscardReason] { Self.keepReasons(of: pages[key]) }

    /// The page ends with its view; the tab's next show makes a new one.
    func viewDiscarded(_ key: String) {
        if let page = pages.removeValue(forKey: key) { services?.webUI.close(page) }
    }

    /// Why a Channels page may not be discarded now, from the reasons it holds itself
    /// (``PageKeepReasons``): its composers' unsent text or files (`cmux.page.keepAlive` `draft`,
    /// composerDrafts.ts) and whatever else its document or the host holds on it (a form, an edit,
    /// a `beforeunload`, a sheet or a menu it opened). None for no page.
    static func keepReasons(of page: PageWebView?) -> [CannotDiscardReason] {
        guard let page else { return [] }
        var reasons: [CannotDiscardReason] = []
        for reason in page.keepReasons.current where reason.blocksDiscard {
            let mapped: CannotDiscardReason = switch reason {
            case .draft, .formInteraction: .formInput
            case .userEdits: .unsavedEdits
            case .beforeUnload: .beforeUnload
            case .inspector: .devTools
            case .capture: .capturing
            default: .inProgress
            }
            if !reasons.contains(mapped) { reasons.append(mapped) }
        }
        return reasons.sorted { $0.rawValue < $1.rawValue }
    }

    @discardableResult
    static func open(_ services: AppServices, focus: Bool = true) -> Bool {
        if services.pages.provider(.homeChannels) == nil { services.pages.register(make(services)) }
        return services.pages.show(.homeChannels, in: services.windows.active, focus: focus) != nil
    }
}

nonisolated enum HomeChannelsStrings {
    static var title: String { String(localized: "homeChannels.page.title", defaultValue: "Channels", table: "Handlers", bundle: .module) }
}
