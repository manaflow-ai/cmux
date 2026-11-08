import AppKit
import CmuxNextBrowser
import CmuxNextCompat

/// What the Markdown omnibar asks of its tab's owner (``FilePageService``).
struct MarkdownOmnibarActions {
    /// Opens a committed URL: `disposition` nil loads it in this tab (a Markdown file in place,
    /// anything else beside it), else in a new tab or window.
    var open: (URL, OmnibarDisposition?) -> Void
    /// Gives the keyboard back to the page (after a commit or Escape).
    var returnFocus: () -> Void
    /// The local live link of a file (``MarkdownLiveShareServer``).
    var liveLink: (URL) async -> URL?
    /// Opens a web URL in a cmux browser tab beside the page.
    var openInBrowser: (URL) -> Void
    /// Back, Forward and Reload (Cmd-[, Cmd-], Cmd-R): the page's link history and the file again
    /// from disk (the page's `back`, `forward` and `reload` commands).
    var back: () -> Void
    var forward: () -> Void
    var reload: () -> Void
}

/// The Markdown tab's top bar (plans/cmux-next/markdown-omnibar-DESIGN.md sections 2 and 2b): the
/// browser's own omnibar row (``OmnibarToolbarView``, one implementation with the browser tab:
/// Back, Forward and Reload, field, glass, suggestions, keys) showing the file's path, a repo chip
/// with the file's git state, and the Share menu on the page-info chip and the repo chip. It only
/// uses the omnibar's public API.
final class MarkdownOmnibarBar: NSView {
    let toolbar: OmnibarToolbarView
    private let reader: MarkdownFileLocationReader
    private let actions: MarkdownOmnibarActions
    private var file: URL?
    private(set) var location: MarkdownFileLocation?
    private var reading: Task<Void, Never>?
    private var canBack = false
    private var canForward = false

    init(suggestionEngine: OmniboxSuggestionEngine, reader: MarkdownFileLocationReader = MarkdownFileLocationReader(),
         actions: MarkdownOmnibarActions) {
        toolbar = OmnibarToolbarView(suggestionEngine: suggestionEngine, navigation: true)
        self.reader = reader
        self.actions = actions
        super.init(frame: .zero)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolbar.onBack = actions.back
        toolbar.onForward = actions.forward
        toolbar.onReload = actions.reload
        let bar = toolbar.addressBar
        bar.onEvent = { [weak self] event in self?.handle(event) }
        bar.onPageInfo = { [weak self] in self?.popUpShareMenu() }
        bar.machineBadgeMenu = { [weak self] in self?.shareMenu() }
        bar.setAccessibilityIdentifier("cmux.markdown.omnibar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The tab shows `file` (nil: the empty state): the field shows its path; the chip follows
    /// once git answers.
    func show(_ file: URL?) {
        let file = file?.standardizedFileURL
        guard file != self.file else { return }
        self.file = file
        location = nil
        updateNavigation()
        toolbar.addressBar.update(url: file, security: .local)
        toolbar.addressBar.setMachineBadge(nil, help: nil)
        reading?.cancel()
        guard let file else { return }
        reading = Task { [weak self, reader] in
            let location = await reader.read(file)
            guard let self, !Task.isCancelled, self.file == file else { return }
            self.apply(location)
        }
    }

    /// The page's link history moved (`cmux.markdown.history`): Back and Forward follow it.
    func setHistory(canBack: Bool, canForward: Bool) {
        self.canBack = canBack
        self.canForward = canForward
        updateNavigation()
    }

    /// Back and Forward follow the page's history; Reload needs a file (not the empty state).
    private func updateNavigation() {
        toolbar.setNavigation(canGoBack: canBack, canGoForward: canForward, canReload: file != nil)
    }

    /// The git state may have changed (a save): read it again.
    func refresh() {
        let file = file
        self.file = nil
        show(file)
    }

    private func apply(_ location: MarkdownFileLocation) {
        self.location = location
        if let git = location.git {
            let help = "\(git.root)\n\(MarkdownShareStrings.state(git.state))"
            toolbar.addressBar.setMachineBadge(git.chipText, help: help)
        } else {
            toolbar.addressBar.setMachineBadge(nil, help: nil)
        }
    }

    /// Focus Location Bar (Cmd-L) on a Markdown tab: the field takes the keyboard, path selected.
    func focusLocation() {
        toolbar.addressBar.focus()
    }

    private func handle(_ event: OmnibarEvent) {
        switch event {
        case .didEndEditing(.commit(let url)):
            toolbar.addressBar.showPageURL()
            actions.returnFocus()
            actions.open(url, nil)
        case .didEndEditing(.open(let url, let disposition)):
            actions.returnFocus()
            actions.open(url, disposition)
        case .didEndEditing(.cancel), .didEndEditing(.keyword), .didEndEditing(.switchToTab):
            toolbar.addressBar.showPageURL()
            actions.returnFocus()
        case .didBeginEditing, .didEndEditing(.blur):
            break
        }
    }

    // MARK: Share menu

    private func popUpShareMenu() {
        let anchor = toolbar.addressBar.pageInfoAnchor
        shareMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
    }

    /// The Share menu (design section 4): path, GitHub link, local live link, Finder, and the
    /// hosted live share, shown but not built yet.
    func shareMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let file else { return menu }
        let location = location
        let header = NSMenuItem(title: location?.displayPath ?? MarkdownFileLocation.tildePath(file.path, home: NSHomeDirectory()),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(MarkdownMenuAction.item(MarkdownShareStrings.copyPath) { Self.copy(file.path) })
        if let git = location?.git, let blob = git.blobURL {
            let title = git.blobIsExact ? MarkdownShareStrings.copyGitHubLink : MarkdownShareStrings.copyGitHubLinkLastPushed
            menu.addItem(MarkdownMenuAction.item(title) { Self.copy(blob.absoluteString) })
        } else if location?.git?.githubRepository != nil {
            let none = NSMenuItem(title: MarkdownShareStrings.noGitHubLink, action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        let actions = actions
        menu.addItem(MarkdownMenuAction.item(MarkdownShareStrings.copyLiveLink) {
            // task-owner: one link request; ends when the server answers
            Task { if let link = await actions.liveLink(file) { Self.copy(link.absoluteString) } }
        })
        menu.addItem(MarkdownMenuAction.item(MarkdownShareStrings.openLiveLink) {
            // task-owner: one link request; ends when the server answers
            Task { if let link = await actions.liveLink(file) { actions.openInBrowser(link) } }
        })
        menu.addItem(MarkdownMenuAction.item(MarkdownShareStrings.revealInFinder) {
            NSWorkspace.shared.revealInBackground([file])
        })
        menu.addItem(.separator())
        let later = NSMenuItem(title: MarkdownShareStrings.liveShareLater, action: nil, keyEquivalent: "")
        later.isEnabled = false
        menu.addItem(later)
        return menu
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
