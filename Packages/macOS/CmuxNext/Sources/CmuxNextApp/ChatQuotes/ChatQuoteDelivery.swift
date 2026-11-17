import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextHome
import CmuxNextPages

/// Puts a viewer quote in its chat's composer as a card (viewer-comments-DESIGN.md), through the
/// design mode highlight's own paths, so both make the same card: the agent chat that opened the
/// file gets ``AgentPaneDesignSelection`` chips; else the Home Messages page of `window` gets the
/// quote as a file in its composer (``HomeComposerHandoff``, as a drop). Nothing is sent.
@MainActor
struct ChatQuoteDelivery {
    let services: AppServices

    func deliver(_ quote: ChatQuote, from window: NSWindow?) {
        let tabs = services.agentTabs
        let target = services.chatQuoteOpeners.target(for: quote.source) { tabs.existingView(tabs.resolve($0))?.model.hasHandshake == true }
        if case .agentTab(let key) = target, let view = tabs.existingView(tabs.resolve(key)) {
            AgentPaneDesignSelection(id: "quote-" + UUID().uuidString, name: quote.title, text: quote.markdown, png: nil).push(to: view)
            return
        }
        let window = window ?? services.windows.active?.window
        var home = HomeComposerHandoff.shown(in: window)
        if home == nil, AppActions.showHome(services) { home = HomeComposerHandoff.shown(in: window) }
        let folder = Self.folder()
        guard let home, let file = try? ChatQuoteFile(folder: folder).write(quote) else {
            services.registry.refuse(RefusalStrings.homeQuoteNoHome)
            return
        }
        let registry = services.registry
        // task-owner: one hand-off of the quote's file; ends with the page's answer (bounded by HomeComposerHandoff.attachDeadline)
        // main-hop-allow: already on main (a viewer's Quote in Chat); the task only awaits the page
        Task { @MainActor in
            let result = await home.attach([file])
            // The page holds the file's bytes once it answers: the folder goes either way.
            await Self.remove(folder)
            if result != .accepted { registry.refuse(RefusalStrings.homeQuoteNoHome) }
        }
    }

    @concurrent
    private nonisolated static func remove(_ folder: URL) async {
        try? FileManager.checked.removeItem(at: folder)
    }

    /// A new folder per quote under the temporary directory, so two quotes of one file never collide.
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-viewer-quotes", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
