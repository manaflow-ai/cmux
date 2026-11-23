import AppKit
import CmuxNextActions
import CmuxNextSettings
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextHome
import Foundation

/// Design mode in browser panes (plans/cmux-next/design-mode-DESIGN.md): turns it on and off for a
/// tab (`toggleBrowserDesignMode`: the toolbar button, the palette, Ctrl-Opt-Cmd-D and the CLI all
/// run this one path), and sends each added pick (a click, its comment, Return) as one card to the
/// Chief's Home composer shown in the browser's window, else to the agent chat of the browser's
/// workspace whose pane was focused last. A pick the chat lets go of (its chip removed, or sent)
/// leaves the page, so the pins always match the chips.
@MainActor
final class BrowserDesignModeController {
    private weak var services: AppServices?
    private let script = BrowserDesignModeScript()
    private let strings = BrowserDesignModeStrings()
    /// What each tab (by tab key) already sent, so a scroll or a repaint sends nothing.
    private var cards: [String: BrowserDesignModeCards] = [:]

    init(services: AppServices) { self.services = services }

    /// Turns design mode on or off for the browser tab `key` (its entry `entry`).
    func toggle(_ entry: BrowserEntry, key: String) {
        let modes = entry.state.modes
        modes.designMode.toggle()
        let on = modes.designMode, tab = entry.tab
        cards[key] = on ? BrowserDesignModeCards() : nil
        Task { [weak self, state = entry.state] in
            guard on else { return await tab.disableDesignMode() }
            do {
                try await tab.enableDesignMode(self?.script ?? BrowserDesignModeScript())
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
        let change = tracker.change(message, pageURL: page.state.url)
        cards[key] = tracker
        guard !change.cards.isEmpty || !change.removed.isEmpty else { return }
        // The Chief's Home chat in the browser's window first (Home on the left, the page on the
        // right), else the workspace's last-used agent chat. A variation pick is sent to Home at once
        // through a304's `home.sendMessage`; other highlights wait in the composer.
        let home = HomeNativeTranscriptView.shown(in: page.contentView.window).flatMap { $0.canAttach ? $0 : nil }
        let chat = home == nil ? chatView(near: key) : nil
        // A highlight removed on the page takes its card out of whichever composer holds it.
        for id in change.removed { takeOut(id, home: home, chat: chat) }
        let made = change.cards
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
            for card in rest {
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
    func release(_ ids: [String]) {
        for id in ids {
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

    /// The agent chat in the workspace of browser tab `key` whose pane was focused last.
    private func chatView(near key: String) -> AgentPaneView? {
        guard let services, let (_, pane) = services.locateTabOnAnyMachine(key) else { return nil }
        let store = services.daemon(for: pane).store
        guard let workspace = store.workspace(containing: pane.handle) else { return nil }
        let panes = workspace.screens.flatMap(\.panes).sorted { $0.focusedAt > $1.focusedAt }
        for candidate in panes {
            let selected = candidate.tabs.indices.contains(candidate.defaultTabIndex) ? [candidate.tabs[candidate.defaultTabIndex]] : []
            for tab in selected + candidate.tabs {
                if let view = services.agentTabs.existingView(tab.id), !services.agentTabs.isNewTabPage(tab.id) { return view }
            }
        }
        return nil
    }
}
