import AppKit
import CmuxNextHibernation
import CmuxNextIcons
import CmuxNextPages

extension InternalPageID {
    static let coderouter = InternalPageID(rawValue: "coderouter")
}

/// The React CodeRouter page as an internal page tab (one per window). `app.open cmux/coderouter`
/// opens it while Debug Settings `coderouter.surface` is `web`; the app's commands still run in
/// the app.
@MainActor
enum CodeRouterPageTab {
    static let appID = "cmux/coderouter"

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc): the page
    /// reads the routes and accounts again when it is made, and its ops run on the control router,
    /// not in the page.
    static let hiddenPolicy = ContentDiscardPolicy.standard

    static func make(_ services: AppServices) -> WebPageTab {
        WebPageTab(.coderouter, symbol: "arrow.triangle.branch", icon: .accountRouted, title: CodeRouterPageStrings.title,
                   discardPolicy: hiddenPolicy) { [weak services] in
            services.flatMap { PageFactory(services: $0).coderouterWebPage() }
        }
    }
}
