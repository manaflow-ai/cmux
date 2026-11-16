import Foundation
import os

/// Extension site styles (`apps-site-styles`) in a Chromium page from the start of each document,
/// before its first paint. The App's one document-start script
/// (``BrowserSharedStores/documentStartScript``, built by ``BrowserSiteControl``) is registered
/// with the tab's browser over DevTools (`Page.addScriptToEvaluateOnNewDocument` in the `cmux`
/// isolated world, the world `evaluate(world: .isolated)` uses). Each new snapshot replaces it:
/// the new script goes in before the old one comes out, so no document starts with neither.
///
/// The DevTools path only: a tab on the renderer paths (fork API 29) keeps no DevTools session, and
/// the renderer's document scripts cannot be replaced, so such a tab keeps the commit-time installers
/// (`CEFTab.pageInfoDocumentCommitted`). Those also cover a document that commits before the script
/// is in (``coversNewDocuments``).
final class CEFSiteStyleBridge {
    /// Weak: the tab owns the relay that owns this bridge.
    private weak var tab: CEFTab?
    /// The script Chromium holds for the tab's browser, and its identifier there.
    private var held: (browser: Int32, source: String, identifier: String)?
    /// A sync pass is running; it reads the wanted script again before it ends.
    private var syncing = false

    init(tab: CEFTab) { self.tab = tab }

    /// Every new document of the tab's browser gets the current styles at its start, so the
    /// commit-time installers have nothing to add.
    var coversNewDocuments: Bool {
        guard let tab, let browser = tab.browserID else { return false }
        let wanted = tab.runtime.stores.documentStartScript
        guard let held else { return wanted.isEmpty }
        return held.browser == browser && held.source == wanted
    }

    /// Brings the browser's script to the current snapshot. One pass at a time; a call during a pass
    /// is picked up by that pass, which repeats until what Chromium holds is what is wanted.
    func sync() {
        guard !syncing, let tab, tab.browserID != nil else { return }
        syncing = true
        // `CEFTab.runtime` is unowned: read on this turn, while the runtime is known alive, and held
        // by the Task (`CEFVerificationBridge.run`).
        let runtime = tab.runtime
        // task-owner: one tab's document-start style script; ends when Chromium holds the wanted one,
        // a call fails, or the tab closes
        Task { [weak self, weak tab] in
            while let self, let tab, !tab.isClosed, let browser = tab.browserID {
                let wanted = runtime.stores.documentStartScript
                let current = self.held.flatMap { $0.browser == browser ? $0 : nil }
                if (current?.source ?? "") == wanted { break }
                var added: String?
                if !wanted.isEmpty {
                    do {
                        let result = try await runtime.devTools(browser, method: "Page.addScriptToEvaluateOnNewDocument",
                                                                params: ["source": wanted, "worldName": Self.world])
                        added = Self.scriptIdentifier(result)
                    } catch {
                        runtime.logger.info("site styles: add failed: \(String(describing: error), privacy: .public)")
                    }
                    guard added != nil else { break }
                }
                if let current {
                    do {
                        _ = try await runtime.devTools(browser, method: "Page.removeScriptToEvaluateOnNewDocument",
                                                       params: ["identifier": current.identifier])
                    } catch {
                        runtime.logger.info("site styles: remove failed: \(String(describing: error), privacy: .public)")
                    }
                }
                self.held = added.map { (browser, wanted, $0) }
            }
            self?.syncing = false
        }
    }

    /// The isolated world the installers run in, at commit and at document start alike.
    nonisolated static let world = "cmux"

    /// The `identifier` of a `Page.addScriptToEvaluateOnNewDocument` result.
    static func scriptIdentifier(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["identifier"] as? String
    }
}
