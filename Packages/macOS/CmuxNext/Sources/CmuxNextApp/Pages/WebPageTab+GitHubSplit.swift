import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout

/// The GitHub page opened straight in a new split (https://github.com/manaflow-ai/cmux/issues/38184):
/// one `new-conversation-tab {page, split}` (`conversation-tab-split-v1`), the split and the page's
/// stand-in tab shown in the click's turn with the chain's even sizing, as a web link's split is
/// (``LinkOpener/browserSplit(_:profile:returningTo:)``). It used to be made hidden in the chat's pane
/// and moved to a new split once the store listed it, so the split played its opening and then the
/// tab moved into it: two animations for one click.
extension WebPageTab {
    /// The ``LinkOpener/SplitMake`` of a GitHub page tab on `route`. Nil (the open makes and moves) for a
    /// daemon without the capability, a pane with no room for a split, a pinned dock that is not Home's
    /// lone dock, or a script's open that may not change the view.
    static func gitHubSplit(_ tab: WebPageTab, route: String, returningTo source: PaneController,
                            services: AppServices) -> LinkOpener.SplitMake {
        { [weak tab, weak source, weak services] pane, direction, finished in
            let daemon = pane.daemon, store = daemon.store
            // Home's dock alone gets its column in the same commit, as a new chat's does (NewChatPlacement).
            let besideDock = direction == .right && daemon.supports(DaemonCapability.pinnedDockAlone.rawValue) && store.isLonePinnedDock(pane.pane.handle)
            guard let tab, let services, daemon.supports(DaemonCapability.conversationTabSplit.rawValue),
                  daemon.supports(DaemonCapability.splitClientKeys.rawValue), ActionRunScope.viewChangeAllowed(),
                  let window = services.windowController(showing: pane),
                  besideDock || !pane.isPinnedDockPane && { if case .split = services.splitRoom(for: pane.pane, edge: direction == .right ? .right : .bottom) { true } else { false } }()
            else { return nil }
            let key = LocalPageTab.makeKey(.github)
            tab.restore(route, for: key)
            let layout = pane.isPinnedDockPane ? nil : pane.workspace?.layoutModel // beside Home's dock it is a column: no even sizing
            let sizing = layout.map { $0.showSplitSizing($0.splitSizingChanges(splitting: pane.layoutPaneID, axis: direction == .right ? .horizontal : .vertical)) }
            let intent = pane.workspace?.beginFocusIntent()
            // A refusal before the request (nothing shown) is the caller's: `finished` runs only for a split that showed.
            var started = false
            let opened = services.pages.openStoreTab(.github, in: pane, window: window, focus: false, key: key, created: { [weak pane] surface in
                if let sizing { layout?.commitSplitSizing(sizing) }
                // As for a web link's split: the page takes the focus, and its close, emptying its pane, gives it back to the chat.
                if let source, let content = source.workspace { services.linkOpener.returnFocus(of: surface, to: source.layoutPaneID, in: content) }
                pane?.workspace?.expectFocus(on: surface, generation: intent)
                // The reply can come before the daemon's pane: the open's turn ends once the store lists the tab,
                // so the next open beside this pane never aims at the provisional pane (BrowserTabSplitCommand).
                services.registry.track(Task { @MainActor in
                    finished(await BrowserTabSplitCommand.listed(surface, in: store) ? surface : nil)
                    return nil
                })
            }, failed: { _ in
                guard started else { return }
                if let sizing { layout?.cancelSplitSizing(sizing) }
                finished(nil)
            }, requiresSurface: true, split: direction) != nil
            started = opened
            if opened {
                pane.workspace?.applyCurrent() // the split draws in the click's frame
            } else if let sizing {
                layout?.cancelSplitSizing(sizing)
            }
            return opened
        }
    }
}
