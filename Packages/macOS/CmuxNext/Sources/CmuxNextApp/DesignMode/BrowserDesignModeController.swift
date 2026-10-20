import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Design mode in browser panes (plans/cmux-next/design-mode-DESIGN.md): turns it on and off for a
/// tab (`toggleBrowserDesignMode`: the toolbar button, the palette, Ctrl-Opt-Cmd-D and the CLI all
/// run this one path), and sends each new highlight as a card to the agent chat of the browser's
/// workspace whose pane was focused last.
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
        let made = tracker.receive(message, pageURL: page.state.url)
        cards[key] = tracker
        guard !made.isEmpty else { return }
        guard let chat = chatView(near: key) else {
            services.cache.existingBrowser(key)?.chrome.showNotice(strings.noAgentChat)
            return
        }
        Task { [weak page, weak chat] in
            guard let page else { return }
            let shot = await Self.capture(page)
            for card in made {
                let png = shot.flatMap { Self.crop($0, to: card) }
                guard let chat else { return }
                AgentPaneDesignSelection(id: card.id, name: card.name, text: card.text, png: png).push(to: chat)
            }
        }
    }

    /// The agent chat in the workspace of browser tab `key` whose pane was focused last.
    private func chatView(near key: String) -> AgentPaneView? {
        guard let services, let (_, pane) = services.locateTab(key) else { return nil }
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
        _ = try? await page.evaluate("globalThis.__cmuxDesignMode?.prepareCapture(); true", world: .isolated)
        let image = try? await page.snapshot()
        _ = try? await page.evaluate("globalThis.__cmuxDesignMode?.finishCapture(); true", world: .isolated)
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
