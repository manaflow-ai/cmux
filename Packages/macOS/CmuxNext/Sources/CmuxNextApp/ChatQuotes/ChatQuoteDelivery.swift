import AppKit
import CmuxNextAgentPane
import CmuxNextDaemonService
import CmuxNextHome
import CmuxNextPages

/// Puts a viewer quote in its chat's composer as a card (viewer-comments-DESIGN.md), through the
/// design mode highlight's own paths, so both make the same card: the agent chat that opened the
/// file gets ``AgentPaneDesignSelection`` chips; else the Chief Home composer of `window` gets the
/// quote as a file through its intake (as a drop). Nothing is sent.
@MainActor
struct ChatQuoteDelivery {
    let services: AppServices

    func deliver(_ quote: ChatQuote, from window: NSWindow?) {
        let tabs = services.agentTabs
        let target = services.chatQuoteOpeners.target(for: quote.source) { tabs.views[tabs.resolve($0)]?.model.hasHandshake == true }
        if case .agentTab(let key) = target, let view = tabs.views[tabs.resolve(key)] {
            AgentPaneDesignSelection(id: "quote-" + UUID().uuidString, name: quote.title, text: quote.markdown, png: nil).push(to: view)
            return
        }
        let window = window ?? services.windows.active?.window
        var home = HomeNativeTranscriptView.shown(in: window)
        if home?.canAttach != true, AppActions.showHome(services) { home = HomeNativeTranscriptView.shown(in: window) }
        guard let home, home.canAttach, let file = try? ChatQuoteFile(folder: Self.folder()).write(quote),
              home.attachFiles(paths: [file.path], via: .drop) == .accepted else {
            services.registry.refuse(RefusalStrings.homeQuoteNoHome)
            return
        }
    }

    /// A new folder per quote under the temporary directory, so two quotes of one file never collide.
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-viewer-quotes", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
