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

    static func make(_ services: AppServices) -> WebPageTab {
        // Ten minutes hidden, the policy it had as a default; page policies batch 5 (p07-memory-028) reviews it.
        WebPageTab(.coderouter, symbol: "arrow.triangle.branch", icon: .accountRouted, title: CodeRouterPageStrings.title,
                   discardPolicy: .standard) { [weak services] in
            services.flatMap { PageFactory(services: $0).coderouterWebPage() }
        }
    }
}
