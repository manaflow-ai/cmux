import AppKit
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
        WebPageTab(.coderouter, symbol: "arrow.triangle.branch", icon: .accountRouted, title: CodeRouterPageStrings.title) { [weak services] in
            services.flatMap { PageFactory(services: $0).coderouterWebPage() }
        }
    }
}
