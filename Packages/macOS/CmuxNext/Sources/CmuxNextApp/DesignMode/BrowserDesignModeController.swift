import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextHome
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Design mode in browser panes (plans/cmux-next/design-mode-DESIGN.md): turns it on and off for a
/// tab (`toggleBrowserDesignMode`: the toolbar button, the palette, Ctrl-Opt-Cmd-D and the CLI all
/// run this one path), and sends each new highlight as a card to the Chief's Home composer shown in
/// the browser's window, else to the agent chat of the browser's workspace whose pane was focused last.
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
        let modes = entry.chrome.toolbarButtons.modes
        modes.designMode.toggle()
        let on = modes.designMode, tab = entry.tab
        cards[key] = on ? BrowserDesignModeCards() : nil
        Task { [weak self, weak chrome = entry.chrome] in
            guard on else { return await tab.disableDesignMode() }
            do {
                try await tab.enableDesignMode(self?.script ?? BrowserDesignModeScript())
            } catch {
                modes.designMode = false
                chrome?.showNotice(self?.strings.couldNotStart ?? "")
            }
        }
    }

    /// A design mode message from `page` (`BrowserTabIntent.designMode`).
    func receive(_ message: Data, from page: any BrowserTab) {
        guard let services, let key = services.cache.key(of: page) else { return }
        if BrowserDesignModeCards.isExitRequest(message) {
            if let entry = services.cache.existingBrowser(key), entry.chrome.toolbarButtons.modes.designMode { toggle(entry, key: key) }
            return
        }
        guard var tracker = cards[key] else { return }
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
            services.cache.existingBrowser(key)?.chrome.showNotice(strings.noAgentChat)
            return
        }
        for case .sendToHome(let text) in deliveries {
            services.registry.perform("home.sendMessage", invocation: ActionInvocation(arguments: ["text": .string(text)]))
        }
        let rest = zip(made, deliveries).filter { if case .sendToHome = $0.1 { return false } else { return true } }.map(\.0)
        guard !rest.isEmpty else { return }
        Task { [weak self, weak page, weak chat, weak home] in
            guard let page else { return }
            let shot = await Self.capture(page)
            for card in rest {
                let png = shot.flatMap { Self.crop($0, to: card) }
                if let home {
                    await self?.attach(card, png: png, to: home)
                } else if let chat {
                    // The same id replaces an edited card's chips in the agent chat composer.
                    AgentPaneDesignSelection(id: card.id, name: card.name, text: card.text, png: png).push(to: chat)
                }
            }
        }
    }

    /// The Home draft attachments each card added, by card id, so an edit or a removal takes them back.
    private var homeAttachments: [String: [String]] = [:]

    /// Takes card `id` out of the Home composer (its attachments) or the agent chat composer (its chips).
    private func takeOut(_ id: String, home: HomeNativeTranscriptView?, chat: AgentPaneView?) {
        if let hashes = homeAttachments.removeValue(forKey: id) {
            home?.removeDraftAttachments(hashes)
        } else if let chat {
            AgentPaneDesignSelection.remove(id, from: chat)
        }
    }

    /// Where cards become files for the Home composer; each card's folder goes once Home has its
    /// copy (``HomeNativeTranscriptView/attachmentsReady()``), the rest at quit.
    nonisolated static let tempFiles = BrowserDesignModeTempFiles(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("cmux-design-mode", isDirectory: true))

    /// Gives the Home composer `card` as files, through its own intake (as a drop), replacing what an
    /// earlier version of the card added, then removes the files once the draft holds Home's copies.
    private func attach(_ card: BrowserDesignModeCard, png: Data?, to home: HomeNativeTranscriptView) async {
        if let old = homeAttachments.removeValue(forKey: card.id) { home.removeDraftAttachments(old) }
        let temp = Self.tempFiles, folder = temp.newFolder()
        guard let files = try? BrowserDesignModeCardFiles(folder: folder).write(card, png: png) else {
            temp.remove(folder)
            return
        }
        await home.attachmentsReady()
        let before = Set(home.draftAttachmentHashes)
        guard home.attachFiles(paths: files.map(\.path), via: .drop) == .accepted else {
            temp.remove(folder)
            return
        }
        await home.attachmentsReady()
        temp.remove(folder)
        homeAttachments[card.id] = home.draftAttachmentHashes.filter { !before.contains($0) }
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

    /// The page as shown, without design mode's own outline and badges.
    private static func capture(_ page: any BrowserTab) async -> CGImage? {
        _ = try? await page.evaluate("globalThis.__cmuxDesignMode?.prepareCapture(); true", world: .isolated, gesture: .cmux)
        let image = try? await page.snapshot()
        _ = try? await page.evaluate("globalThis.__cmuxDesignMode?.finishCapture(); true", world: .isolated, gesture: .cmux)
        return image
    }

    /// The card's element cut from the page image, as PNG; nil when it is off the page or empty.
    nonisolated static func crop(_ image: CGImage, to card: BrowserDesignModeCard) -> Data? {
        guard card.viewportWidth > 0 else { return nil }
        let scale = Double(image.width) / card.viewportWidth
        let rect = CGRect(x: card.bounds.minX * scale, y: card.bounds.minY * scale,
                          width: card.bounds.width * scale, height: card.bounds.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let cut = image.cropping(to: rect) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cut, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
