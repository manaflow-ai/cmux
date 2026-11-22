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
final class CodeRouterPageTab: InternalPageProvider {
    static let appID = "cmux/coderouter"
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .coderouter }
    var title: String { CodeRouterPageStrings.title }
    var symbol: String { "arrow.triangle.branch" }
    var icon: IconName? { .accountRouted }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services, let view = PageFactory(services: services).coderouterWebPage() else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        pages.removeValue(forKey: key)?.close()
    }
}
