import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// A native New Tab page's asks for the Commands palette's actions (``AgentPaneNewTabActions``).
///
/// A page that shows while the last list still holds takes it with no read, so a hold of the New Tab key starts
/// no listing. Such a list was read before the page showed, and an action's own rule can read a state that is no
/// part of what the list is kept by: the person's first use of the page (a typed letter, a run of a row) reads the
/// actions again. So does a page whose listing had no key (it saw two focus contexts or a change of the registry).
/// A page whose own listing read its list under one key reads nothing more.
///
/// ```swift
/// let list = NativeNewTabList(lister)
/// let model = NativeNewTabModel(page: page, actions: actions, list: list)
/// ```
@MainActor
public final class NativeNewTabList {
    private let lister: AgentPaneNewTabActions
    /// A listing with a key was read for this page: its first use asks for nothing.
    private var own = false
    /// The page, for the rows of a list read after a run that the palette refused.
    public fileprivate(set) weak var model: NativeNewTabModel?

    /// - Parameter lister: The app's lister of the palette's actions.
    public init(_ lister: AgentPaneNewTabActions) { self.lister = lister }

    /// Gives `page`, which shows now, the kept list when one holds (``AgentPaneNewTabActions/kept``). When none
    /// holds, returns the page's ask after it shows (``NativeNewTabModel/loadPaletteActions()``): a listing.
    public func show(in page: inout AgentPaneNewTab) -> NativeNewTabModel.PaletteActionsRequest? {
        if let kept = lister.kept {
            page.omnibar.actions = kept.actions
            return nil
        }
        return { [self] wanted, deliver in
            lister.list(wanted: wanted) { [self] listed in
                if !lister.firstUseReads { own = true }
                deliver(listed.actions)
            }
        }
    }

    /// The page's ask at its person's first use: a listing, unless one was read for the page already.
    public var use: NativeNewTabModel.PaletteActionsRequest {
        { [self] wanted, deliver in
            guard !own else { return }
            own = true
            read(wanted, deliver)
        }
    }

    /// The page's run of an action row (``NativeNewTabActions/action``). A row that the palette refuses now (it
    /// cannot run, or its title is not the shown one any more) makes the actions be read again: the row leaves the
    /// list or changes, as the palette's own list dims it.
    ///
    /// - Parameter run: Runs the palette's row of an id when its title is still the shown one; false when the
    ///   palette refused it.
    public func action(_ run: @escaping @MainActor (_ id: String, _ shown: String) -> Bool) -> @MainActor (String, String) -> Void {
        { [self] id, shown in
            if !run(id, shown) { refused() }
        }
    }

    private func refused() { model?.listPaletteActions(by: read) }

    private func read(_ wanted: @escaping @MainActor () -> Bool, _ deliver: @escaping @MainActor ([AgentPaneOmnibar.Action]) -> Void) {
        lister.read(wanted: wanted) { deliver($0.actions) }
    }
}

extension NativeNewTabModel {
    /// Creates the model of a native page whose palette actions come from `list`: the page shows with the kept list
    /// when one holds, asks `list` at its person's first use, and takes the rows of a list read after a refused run.
    ///
    /// - Parameters:
    ///   - page: The page's context, built without the palette's actions.
    ///   - actions: What the page asks its host to do.
    ///   - list: The page's asks for the palette's actions; one for each page.
    ///   - chats: The device's newest chats (the host's Chats feed), for the chat rows.
    ///   - favicons: The host's asynchronous favicon source, if it has one.
    public convenience init(page: AgentPaneNewTab, actions: NativeNewTabActions, list: NativeNewTabList, chats: [AgentPaneDeviceChat] = [],
                            favicons: NativeNewTabFavicons? = nil) {
        var shown = page
        let show = list.show(in: &shown)
        self.init(page: shown, actions: actions, paletteActions: show, paletteRefresh: list.use, chats: chats, favicons: favicons)
        list.model = self
    }

    /// Cmd-T adopted this prepared page (``adopt(page:actions:paletteActions:paletteRefresh:chats:)``), with the asks
    /// of `list` as ``init(page:actions:list:chats:)`` takes them.
    ///
    /// - Parameters:
    ///   - page: The new tab's context, built without the palette's actions.
    ///   - actions: What the page asks its host to do, for the tab it now is.
    ///   - list: The page's asks for the palette's actions; one for each page.
    ///   - chats: The device's newest chats (the host's Chats feed), for the chat rows.
    ///   - favicons: The host's asynchronous favicon source for the tab it now is.
    public func adopt(page: AgentPaneNewTab, actions: NativeNewTabActions, list: NativeNewTabList, chats: [AgentPaneDeviceChat] = [],
                      favicons: NativeNewTabFavicons? = nil) {
        var shown = page
        let show = list.show(in: &shown)
        adopt(page: shown, actions: actions, paletteActions: show, paletteRefresh: list.use, chats: chats)
        self.favicons = favicons
        list.model = self
    }
}

extension AgentPaneNewTabActions {
    /// One New Tab page as ``fill(again:_:)`` sees it: its view, when it has one.
    public struct Page {
        let view: AgentPaneView?
        /// The page shows no palette action. A page with no view shows none.
        let lacks: Bool

        /// - Parameter view: The page's view; nil before it is made (Cmd-N's first page before its pane shows it, the
        ///   page of a tab that its pane does not show).
        public init(view: AgentPaneView?) {
            self.view = view
            lacks = view.map { $0.model.newTab?.omnibar.actions.isEmpty == true } ?? true
        }
    }

    /// Lists the palette's actions for the New Tab pages that show without them, as background work from the next
    /// frame on (a slice of actions per task, yielding to input), so Cmd-T and Cmd-N never wait for them and the
    /// open's frames never hold the whole list (PACING TRIAGE #32910). A page with a view takes them in place
    /// (``AgentPaneView/refreshNewTabActions(_:)``).
    ///
    /// While the last list holds (``kept``) the pages take it and nothing is read. A page that took it, or a list
    /// whose listing had no key (``firstUseReads``), reads the actions again at its person's first input.
    ///
    /// A page with no view takes no list, and the page that the app stores for it never has one. A stored list has
    /// nothing that says what it was read under: the view made from it later would show it after a change of the
    /// registry or of the focus's context too, and would read nothing again. Such a page still asks for a listing,
    /// so a list is kept when its view is made. The app asks again at the view's make, and the view takes the kept
    /// list, or a listing's, then.
    ///
    /// - Parameters:
    ///   - again: Reads the actions again and gives them to every page that has a view: after a page's first use, and
    ///     after a run of a row that the palette refused. A page whose list is equal sends nothing.
    ///   - pages: The New Tab pages of now, asked at the listing's first task and at its hand-over.
    public func fill(again: Bool = false, _ pages: @escaping @MainActor @Sendable () -> [Page]) {
        if again {
            return read(wanted: { !pages().isEmpty }) { listed in
                for page in pages() { page.view?.refreshNewTabActions(listed) }
            }
        }
        // Checked at the listing's first task: Cmd-N's page joins the app's pages after this call.
        list(wanted: { pages().contains(where: \.lacks) }) { [weak self] listed in
            guard let self else { return }
            let again = firstUseReads
            for page in pages() {
                guard page.lacks, let view = page.view else { continue }
                view.refreshNewTabActions(listed)
                if again { readAtFirstUse(view.model, pages) }
            }
        }
    }

    /// Reads the actions again when a person first uses `page` (the page reports its first input, `newTab.touched`;
    /// its boot traffic does not count): one tracking of the page's own flag for each page model, no hook in the
    /// page. A page that no person used can take the kept list many times (it goes back to the prepared pages): the
    /// tracking that is armed stays the only one, so its first input is one read. The write of the flag only asks,
    /// in the main queue's next turn; the read's first slice runs in a later frame.
    private func readAtFirstUse(_ page: AgentPaneModel, _ pages: @escaping @MainActor @Sendable () -> [Page]) {
        let again: @MainActor @Sendable () -> Void = { [weak self] in self?.fill(again: true, pages) }
        if page.userTouched { return again() }
        let tracking = firstInputs.object(forKey: page) ?? SingleArmedTracking()
        firstInputs.setObject(tracking, forKey: page)
        tracking.track(shape: []) { _ = page.userTouched } onChange: { MainDelivery().later(again) }
    }
}
