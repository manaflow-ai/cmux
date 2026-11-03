import AppKit
import CmuxNextActions
import CmuxNextChiefMemory
import CmuxNextHomeEngine
import CmuxNextPages
import CmuxNextSettings
import Foundation

extension PageDescriptor {
    static let importHistory = PageDescriptor(
        id: "cmux.import-history", resource: "import-history", namespaces: ["cmux.importHistory."],
        nativeOps: [PageNativeOp.clipboardWrite])
}

extension InternalPageID {
    static let importHistory = InternalPageID(rawValue: "import-history")
}

/// The native shell only hosts the page; selection, preview and progress live in TypeScript.
@MainActor
final class ImportHistoryPageService: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]
    var onFinish: ((Bool) -> Void)?

    init(services: AppServices) { self.services = services }

    func open(focus: Bool) throws {
        guard let services,
              services.pages.show(.importHistory, in: services.windows.active, focus: focus) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }

    var page: InternalPageID { .importHistory }
    var title: String { ChiefMemoryImportStrings.title }
    var symbol: String { "square.and.arrow.down" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let home = HomeBrainHost.muxHome(tag: services.environment.tag).path
        let provider = ImportHistoryPageProvider(muxHome: home, personOnlyMessage: RefusalStrings.personOnlyFromPage) { arguments, timeout in
            guard let tool = ChiefMemoryImportHandlers.bundledTool() else {
                throw PageError(code: "cmux.importHistory.no_tool", message: ChiefMemoryImportStrings.noTool)
            }
            let output = await ChiefMemoryImportHandlers.run(tool, arguments, timeout: timeout)
            guard output.status == 0 else { throw PageError(code: "cmux.importHistory.failed", message: output.message) }
            return try JSONDecoder().decode(JSONValue.self, from: Data(output.stdout.utf8))
        }
        provider.restart = { [weak services] in _ = services?.home.brain.ensure(asked: true) }
        provider.finish = { [weak self, weak services, weak window] completed in
            self?.onFinish?(completed)
            if window?.shownTopPage == .page(.importHistory) {
                window?.leaveTopPage()
            } else if let services, let pane = services.paneController(showingTab: key),
                      let tab = services.pages.stripID(showing: key, in: pane) {
                pane.close([tab])
            }
        }
        let native = AppPageNativeProvider(services: services, page: .importHistory)
        let routes = [PageRoute(prefix: "cmux.importHistory.", provider: provider),
                      PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: .importHistory, routes: routes) else { return NSView() }
        provider.anchor = { [weak page] in page?.window }
        native.anchor = { [weak page] in page }
        pages[key] = page
        return page
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }
}
