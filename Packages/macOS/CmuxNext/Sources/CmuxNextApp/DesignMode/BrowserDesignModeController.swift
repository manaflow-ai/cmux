import AppKit
import CmuxNextActions
import CmuxNextSettings
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDiff
import CmuxNextHome
import Foundation

/// Design mode in browser panes (plans/cmux-next/design-mode-DESIGN.md): turns it on and off for a
/// tab (`toggleBrowserDesignMode`: the toolbar button, the palette, Ctrl-Opt-Cmd-D and the CLI all
/// run this one path), and sends each added pick (a click, its comment, Return) as one card to the
/// Chief's Home composer shown in the browser's window, else to the agent chat of the browser's
/// workspace whose pane was focused last. A pick the chat lets go of (its chip removed, or sent)
/// leaves the page, so the pins always match the chips.
///
/// Comment threads (cmuxterm-hq goals/all-surface-comments-round-trip.md): when the chat's session
/// host keeps them (`diff-comments-threads-v1`), Command-Return in a pick's bubble sends the pick to that
/// chat at once (``BrowserCommentThreads``: `diff.comments.save` as a browser comment, then
/// a threaded `diff.comments.send`), with no chip, and the pick's thread card on the page shows
/// "Sent", then the agent's reply; Resolve deletes it. Without the capability the chip path stays.
@MainActor
final class BrowserDesignModeController {
    private weak var services: AppServices?
    private let script = BrowserDesignModeScript()
    private let strings = BrowserDesignModeStrings()
    /// What each tab (by tab key) already sent, so a scroll or a repaint sends nothing.
    private var cards: [String: BrowserDesignModeCards] = [:]
    /// The comment threads sent from picks, keyed by card id; each change is drawn on its pick's page.
    private lazy var threads: BrowserCommentThreads = {
        let threads = BrowserCommentThreads()
        threads.onChange = { [weak self, weak threads] id, thread in
            guard let pick = threads?.picks[id], let page = self?.services?.cache.existingBrowser(pick.tab)?.tab else { return }
            Task { [weak page] in await page?.setDesignModeThread(pick.selector, state: thread?.state.rawValue, reply: thread?.reply) }
        }
        return threads
    }()

    init(services: AppServices) { self.services = services }

    /// Turns design mode on or off for the browser tab `key` (its entry `entry`).
    func toggle(_ entry: BrowserEntry, key: String) {
        let modes = entry.state.modes
        modes.designMode.toggle()
        let on = modes.designMode, tab = entry.tab
        cards[key] = on ? BrowserDesignModeCards() : nil
        _ = threads.offer(nil, on: key)
        Task { [weak self, state = entry.state] in
            guard on else { return await tab.disableDesignMode() }
            do {
                try await tab.enableDesignMode(self?.script ?? BrowserDesignModeScript())
                self?.offerSend(on: tab, key: key)
            } catch {
                modes.designMode = false
                state.showNotice(self?.strings.couldNotStart ?? "")
            }
        }
    }

    /// A design mode message from `page` (`BrowserTabIntent.designMode`).
    func receive(_ message: Data, from page: any BrowserTab) {
        guard let services, let key = services.cache.key(of: page) else { return }
        if BrowserDesignModeCards.isExitRequest(message) {
            if let entry = services.cache.existingBrowser(key), entry.state.modes.designMode { toggle(entry, key: key) }
            return
        }
        guard var tracker = cards[key], !page.completeDesignModeCapture(message) else { return }
        if let request = BrowserDesignModeCards.threadRequest(message) {
            return handle(request, tracker: tracker, page: page, key: key)
        }
        offerSend(on: page, key: key)
        let change = tracker.change(message, pageURL: page.state.url)
        cards[key] = tracker
        guard !change.cards.isEmpty || !change.removed.isEmpty else { return }
        // The Chief's Home chat in the browser's window first (Home on the left, the page on the
        // right), else the workspace's last-used agent chat. A variation pick is sent to Home at once
        // through a304's `home.sendMessage`; other highlights wait in the composer.
        let home = HomeNativeTranscriptView.shown(in: page.contentView.window).flatMap { $0.canAttach ? $0 : nil }
        let chat = home == nil ? self.chat(near: key)?.view : nil
        // A highlight removed on the page takes its card out of whichever composer holds it; a
        // threaded pick removed on the page resolves its thread.
        for id in change.removed {
            if threads.threads[id] != nil { resolveThread(id) } else { takeOut(id, home: home, chat: chat) }
        }
        // A pick sent as a thread has no chip: its thread card on the page holds it.
        let made = change.cards.filter { threads.threads[$0.id] == nil }
        guard !made.isEmpty else { return }
        let deliveries = made.map { BrowserDesignModeDelivery($0, homeShown: home != nil, agentChat: chat != nil) }
        if deliveries.contains(.nowhere) {
            services.cache.existingBrowser(key)?.state.showNotice(strings.noAgentChat)
            return
        }
        for case .sendToHome(let text) in deliveries {
            services.registry.perform("home.sendMessage", invocation: ActionInvocation(arguments: ["text": .string(text)]))
        }
        let rest = zip(made, deliveries).filter { if case .sendToHome = $0.1 { return false } else { return true } }.map(\.0)
        guard !rest.isEmpty else { return }
        Task { [weak self, weak page, weak chat, weak home] in
            guard let page else { return }
            // Only the agent chat shows the crop; Home's one file per pick is the card's text.
            let shot = home == nil ? await page.designModeSnapshot() : nil
            // A pick sent as a thread meanwhile (Command-Return right after the snapshot) gets no chip.
            for card in rest where self?.threads.threads[card.id] == nil {
                let png = shot.flatMap { card.crop(from: $0) }
                if let home {
                    // One file per pick: Home draws each file as its own chip, and two per pick
                    // (the text and the crop) was the clutter David Beyer pointed at.
                    await self?.attach(card, to: home)
                } else if let chat {
                    // One chip per pick, its crop inside it; the same id replaces an edited card's chip.
                    AgentPaneDesignSelection(id: card.id, name: card.name, text: card.text, png: png).push(to: chat)
                    chat.designSelectionReleased = { [weak self] ids in self?.release(ids) }
                }
            }
        }
    }

    /// Takes the picks of card `ids` off their pages: a chat removed their chips, or sent them.
    /// A pick sent as a thread stays: its chip left because the thread holds it.
    func release(_ ids: [String]) {
        for id in ids where threads.threads[id] == nil {
            guard let (key, tracker) = cards.first(where: { $0.value.selector(of: id) != nil }), let selector = tracker.selector(of: id),
                  let page = services?.cache.existingBrowser(key)?.tab else { continue }
            Task { [weak page] in await page?.removeDesignModePick(selector) }
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.design_mode {draft?, comment?, commit?}` (captures and tours): types `draft` into the
    /// open comment bubble of the tab in design mode, or `comment` and adds it, or adds what is typed
    /// (`commit: true`), through the runtime's own path. `ok` false when no tab is in design mode.
    static func debugDrive(_ params: [String: CmuxNextSettings.JSONValue], services: AppServices?) async -> CmuxNextSettings.JSONValue {
        let cards = services?.designMode.cards ?? [:]
        guard let page = services?.cache.browsers.first(where: { cards[$0.key] != nil })?.value.tab else { return ["ok": .bool(false)] }
        let commit = params["comment"] != nil || params["commit"]?.boolValue == true
        return ["ok": .bool(await page.driveDesignMode(draft: params["comment"]?.stringValue ?? params["draft"]?.stringValue, commit: commit))]
    }
    #endif

    /// The Home draft attachments each card added: an edit or a removal takes them back; a sent or removed chip frees its pick.
    private var homePicks = BrowserDesignModeHomePicks()

    /// Takes card `id` out of the Home composer (its attachments) or the agent chat composer (its chips).
    private func takeOut(_ id: String, home: HomeNativeTranscriptView?, chat: AgentPaneView?) {
        if let hashes = homePicks.take(id) { home?.removeDraftAttachments(hashes) } else if let chat {
            AgentPaneDesignSelection.remove(id, from: chat)
        }
    }

    /// Where cards become files for the Home composer; each card's folder goes once Home has its
    /// copy (``HomeNativeTranscriptView/attachmentsReady()``), the rest at quit.
    nonisolated static let tempFiles = BrowserDesignModeTempFiles(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("cmux-design-mode", isDirectory: true))

    /// Gives the Home composer `card` as files, through its own intake (as a drop), replacing what an
    /// earlier version of the card added, then removes the files once the draft holds Home's copies.
    private func attach(_ card: BrowserDesignModeCard, to home: HomeNativeTranscriptView) async {
        if let old = homePicks.take(card.id) { home.removeDraftAttachments(old) }
        home.onDraftAttachmentsChange = { [weak self] hashes in if let self { release(homePicks.released(keeping: hashes)) } }
        let temp = Self.tempFiles, folder = temp.newFolder()
        defer { temp.remove(folder) }
        guard let files = try? BrowserDesignModeCardFiles(folder: folder).write(card, png: nil),
              let added = await home.addDraftFiles(files.map(\.path)) else { return }
        homePicks.record(card.id, added: added)
    }

    /// The agent chat in the workspace of browser tab `key` whose pane was focused last, with its tab
    /// and the workspace that holds both.
    private func chat(near key: String) -> (view: AgentPaneView, tab: TabModel, workspace: WorkspaceModel)? {
        guard let services, let (_, pane) = services.locateTabOnAnyMachine(key),
              let chat = services.workspaceAgentChat(near: pane) else { return nil }
        return (chat.view, chat.tab, chat.workspace)
    }
}

extension AppServices {
    /// The agent chat in the workspace of `pane` whose pane was focused last: its tab, view and the
    /// workspace that holds both. Design mode's picks and a terminal selection's comments go to it.
    func workspaceAgentChat(near pane: PaneModel) -> (tab: TabModel, view: AgentPaneView, workspace: WorkspaceModel)? {
        let store = daemon(for: pane).store
        guard let workspace = store.workspace(containing: pane.handle) else { return nil }
        let panes = workspace.screens.flatMap(\.panes).sorted { $0.focusedAt > $1.focusedAt }
        for candidate in panes {
            let selected = candidate.tabs.indices.contains(candidate.defaultTabIndex) ? [candidate.tabs[candidate.defaultTabIndex]] : []
            for tab in selected + candidate.tabs {
                if let view = agentTabs.existingView(tab.id), !agentTabs.isNewTabPage(tab.id) {
                    return (tab, view, workspace)
                }
            }
        }
        return nil
    }
}

// MARK: Comment threads

extension BrowserDesignModeController {
    /// Where a pick of browser tab `key` goes as a thread: the chat ``chat(near:)`` picks, when it
    /// has an acpmux session and its session host keeps comment threads (`diff-comments-threads-v1`),
    /// while Labs `labs.commentThreads` is on (off: the card sends a chip, as before).
    private func threadTarget(near key: String) -> (view: AgentPaneView, session: String, git: DiffAgentGit,
                                                     folder: String?)? {
        guard let services, services.settings?.snapshot.commentThreads == true, let (view, tab, workspace) = chat(near: key),
              let session = tab.agentSession?.session, !session.isEmpty,
              let link = services.viewers.diffPages.gitLink(for: tab), link.supportsDiffCommentThreads else { return nil }
        let folder = NewTerminalStart.folder(of: tab, services: services) ?? workspace.agentFolder
        return (view, session, DiffAgentGit(link: link), folder)
    }

    /// Tells the page of tab `key` whether Command-Return sends, when that changed.
    /// Home's composer takes picks while it is shown, so sending is only for the workspace's chat.
    private func offerSend(on page: any BrowserTab, key: String) {
        let available = HomeNativeTranscriptView.shown(in: page.contentView.window) == nil && threadTarget(near: key) != nil
        guard threads.offer(available, on: key) else { return }
        Task { [weak page] in await page?.setDesignModeSendAvailable(available) }
    }

    /// Command-Return on a pick (a real key in its bubble) sends it to the workspace's chat as a
    /// thread under a fresh opid; its chip, if any, leaves. Resolve on its card, or the pick removed,
    /// deletes the thread and takes the pick off the page.
    private func handle(_ request: BrowserDesignModeThreadRequest, tracker: BrowserDesignModeCards, page: any BrowserTab, key: String) {
        switch request {
        case .send(let selector):
            guard let card = tracker.card(at: selector), HomeNativeTranscriptView.shown(in: page.contentView.window) == nil,
                  threads.threads[card.id].map({ $0.state == .failed && $0.commentID == nil }) ?? true else { return }
            guard let target = threadTarget(near: key) else { return notice(strings.noAgentChat, key) }
            let pick = BrowserCommentPick(tab: key, selector: selector)
            threads.hold(card.id, pick: pick)
            AgentPaneDesignSelection.remove(card.id, from: target.view)
            let comment = BrowserComment(url: page.state.url?.absoluteString ?? "", title: page.state.title, selector: card.selector,
                                         quote: card.quote, message: card.comment, prompt: card.text)
            Task { [weak self] in
                do {
                    try await self?.threads.send(comment, key: card.id, pick: pick, git: target.git,
                                                 folder: target.folder, acpSession: target.session, opid: "browser-comment-" + UUID().uuidString)
                } catch { self?.notice(self?.strings.sendFailed ?? "", key) }
            }
        case .resolve(let selector):
            guard let id = tracker.card(at: selector)?.id ?? threads.key(of: BrowserCommentPick(tab: key, selector: selector)) else { return }
            resolveThread(id)
        }
    }

    private func notice(_ text: String, _ key: String) {
        services?.cache.existingBrowser(key)?.state.showNotice(text)
    }

    private func resolveThread(_ id: String) {
        let pick = threads.picks[id]
        Task { [weak self] in
            try? await self?.threads.resolve(id)
            guard let pick, let page = self?.services?.cache.existingBrowser(pick.tab)?.tab else { return }
            await page.removeDesignModePick(pick.selector)
        }
    }
}
