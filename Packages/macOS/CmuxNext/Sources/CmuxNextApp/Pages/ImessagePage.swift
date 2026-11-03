import AppKit
import CmuxNextActions
import CmuxNextPages

extension InternalPageID {
    static let imessage = InternalPageID(rawValue: "imessage")
}

/// The Messages mirror page (``PageDescriptor/imessage``) as an internal page tab, one per window.
/// `imessage.show` (palette, Window menu) shows it. The page itself says when the mirror is off
/// (`imessage.enabled`, off by default) or lacks Full Disk Access; `cmux.imessage.` goes to the
/// daemon relay, `cmux.imessage.privacy.` to ``ImessagePrivacyPageRoute``.
enum ImessagePageTab {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(WebPageTab(.imessage, symbol: "message", title: ImessagePage.title) { [weak services] in
            guard let services else { return nil }
            let privacy = ImessagePrivacyPageRoute { url in NSWorkspace.shared.open(url) }
            let routes = [PageRoute(prefix: ImessagePrivacyPageRoute.prefix, provider: privacy)]
                + PageFactory(services: services).pageRoutes(for: .imessage)
            guard let page = PageWebView(descriptor: .imessage, routes: routes) else { return nil }
            PageConnectionWatch(page: page, store: services.machines.local.store).start()
            return page
        })
        registry.bind("imessage.show", invoke: { [weak services] invocation in
            if let services { _ = services.pages.show(.imessage, in: services.windows.active, focus: invocation.allowsViewChange) }
        })
    }
}
