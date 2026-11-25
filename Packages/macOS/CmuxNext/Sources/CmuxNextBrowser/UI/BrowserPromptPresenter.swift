public import AppKit

/// Shows a page's pending prompts in a window that has no browser chrome of its own: a popup window
/// (`BrowserPopupWindow`). A tab's chrome (`BrowserChromeView`) shows the first pending prompt as a
/// dialog or in the prompt bar; a popup used to show none, so a question a popup raised (an OAuth
/// window ending on `vscode://` or `slack://`, a JavaScript dialog) waited with nobody able to answer
/// it, and the sign-in hung (Leo 2026-11-24, after cmux#53071: "this is fixable. I feel like there is
/// similar thing maybe with probably logins and redirects and popups and whatnot", ask-2d244f2b2e).
/// The prompt list stays the model, so the automation broker can answer too.
@MainActor
public final class BrowserPromptPresenter {
    private let tab: any BrowserTab
    private weak var container: NSView?
    private let dialogs = BrowserPromptDialogs()
    private var bar: PromptBarView?
    private var loop: ObservationLoop?

    /// Presents `tab`'s prompts over `container`, the view that holds the page (`tab.contentView`).
    public init(tab: any BrowserTab, container: NSView) {
        self.tab = tab
        self.container = container
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    /// True while a prompt of the page is on screen, as a dialog or in the bar.
    public var isShowing: Bool {
        dialogs.isShowing || (bar.map { !$0.isHidden && $0.superview != nil } ?? false)
    }

    /// Ends the presenter with its window: the dialog goes away, the bar goes.
    public func stop() {
        loop?.cancel()
        loop = nil
        dialogs.dismissShown()
        bar?.removeFromSuperview()
    }

    private func render() {
        let first = tab.pendingPrompts.first
        guard let container else { return }
        dialogs.render(first, in: container, shownBar: bar) { makeBar(in: container) }
        syncOcclusion()
    }

    private func makeBar(in container: NSView) -> PromptBarView {
        if let bar { return bar }
        let made = PromptBarView()
        made.translatesAutoresizingMaskIntoConstraints = false
        made.isHidden = true
        container.addSubview(made)
        let page = tab.contentView
        NSLayoutConstraint.activate([
            made.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            made.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            made.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 8),
        ])
        bar = made
        return made
    }

    /// A Chromium page draws in a child window above this view: the bar's rect is cut out of it so the bar shows.
    private func syncOcclusion() {
        guard let occluded = tab as? any BrowserOcclusionHosting, let container else { return }
        container.layoutSubtreeIfNeeded()
        let wanted = bar.flatMap { $0.isHidden || $0.superview == nil ? nil : [container.convert($0.frame, to: tab.contentView)] } ?? []
        if occluded.occlusionRects != wanted { occluded.occlusionRects = wanted }
    }
}
