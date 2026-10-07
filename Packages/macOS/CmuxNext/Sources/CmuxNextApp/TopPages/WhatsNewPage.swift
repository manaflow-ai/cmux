import AppKit
import CmuxNextActions
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSidebar
import CmuxNextUpdater
import SwiftUI

extension InternalPageID {
    static let whatsNew = InternalPageID(rawValue: "whats-new")
}

/// What's New after an update (WHATS-NEW-AFTER-UPDATE W1): a top page like
/// Home and the App Store, opened by the client-only sidebar item at the
/// very top (shown until the user opens it), the palette, the Help menu and
/// `updates.whatsNew`. One path opens it: ``open(_:in:)``.
@MainActor
enum WhatsNewPage {
    static let route = TopPageRoute.page(.whatsNew)
    static let sidebarItemID = LayoutItemID(LayoutItemID.transientPrefix + "whats-new")
    /// Where feed documents' media load from (the web page serves the same files).
    static let webMediaBase = URL(string: "https://cmux.com/whats-new/")

    /// Opens the page in `state`'s window (else the active one) and marks
    /// every version up to this one seen. A run that may not change the
    /// view (automation) opens nothing and leaves the item.
    @discardableResult
    static func open(_ services: AppServices, in state: WindowState? = nil) -> Bool {
        guard ActionRunScope.viewChangeAllowed() else { return false }
        register(services)
        services.updater.whatsNew.open()
        return TopPages.show(route, services: services, in: state) != nil
    }

    /// A click on a client-only sidebar item: the What's New item opens the page.
    static func activateClientItem(_ id: LayoutItemID, services: AppServices, in state: WindowState?) {
        if id == sidebarItemID { open(services, in: state) }
    }

    static func register(_ services: AppServices) {
        if services.pages.provider(.whatsNew) == nil { services.pages.register(WhatsNewTopPage(services: services)) }
    }

    /// The sidebar item while it shows: after an update until opened, and
    /// while this window shows the page.
    static func sidebarItem(center: WhatsNewCenter, shownPage: TopPageRoute?) -> SidebarTransientItem? {
        let showing = shownPage == route
        guard center.showsItem || showing else { return nil }
        var info = SidebarItemInfo(title: WhatsNewPageStrings.title, symbol: "sparkles")
        info.unreadDot = center.showsItem
        return SidebarTransientItem(id: sidebarItemID, info: info)
    }

    /// Whether this build runs `tryIt` from a document of `origin`: bundled
    /// documents were reviewed with the app (any action, any cmux:// link);
    /// feed documents run only the changelog's allow-listed actions.
    static func canTry(_ tryIt: WhatsNewDocument.TryIt, origin: WhatsNewDocument.Origin) -> Bool {
        switch origin {
        case .bundled: true
        case .feed: tryIt.action.map { PageDescriptor.changelogTryItActions.contains($0) } ?? false
        }
    }

    static func actions(_ services: AppServices) -> WhatsNewPageActions {
        WhatsNewPageActions(
            tryIt: { [weak services] tryIt in
                guard let services else { return }
                if let action = tryIt.action {
                    _ = services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(origin: .user))
                } else if let link = tryIt.deeplink {
                    _ = services.registry.perform("link.open", invocation: ActionInvocation(arguments: ["url": .string(link)], origin: .user))
                }
            },
            openDocs: { [weak services] url in
                guard let services else { return }
                HistoryRestorer(services: services).openPage(url.absoluteString, profile: nil, newTab: true)
            },
            openAllNotes: { [weak services] in
                guard let services else { return }
                ChangelogPageTab.open(services)
            },
            mediaURL: { path, origin in
                switch origin {
                case .bundled: BundledWhatsNewSource.app.mediaURL(path)
                case .feed: webMediaBase.map { $0.appending(path: path) }
                }
            })
    }
}

nonisolated enum WhatsNewPageStrings {
    static var title: String { String(localized: "whatsNew.page.title", defaultValue: "What's New", table: "Handlers", bundle: .module) }
}
