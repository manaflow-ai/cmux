import AppKit

/// The covers of parked New Tab spares (CmuxNextApp's `NewTabSparePool`): each page's own frame at its size, its
/// adoption's cover (`AgentTabContent.coverMove`), not the last New Tab page shown, drawn at another size or moment
/// (4 px off, 2026-10-15). One capture generation per page, taken when the page is parked, fitted or prepared, never in
/// a handout's turn (a WebKit snapshot in Cmd-T's motion).
@MainActor
public final class AgentPaneSpareCovers {
    private var generations: [ObjectIdentifier: UInt64] = [:]

    public init() {}

    /// Captures `view`'s cover once it painted, while `parked(view)` holds; a late capture of the page replaces it.
    public func capture(_ view: AgentPaneView, parked: @escaping @MainActor (AgentPaneView) -> Bool, completion: @escaping @MainActor () -> Void = {}) {
        let id = ObjectIdentifier(view)
        guard parked(view) else { return }
        view.redraw.newTabFrameCaptureChanged = { [weak self, weak view] capturing in
            guard let self, let view, parked(view) else { return }
            // A late chats.page answer invalidates the first cover: the replacement capture follows.
            if capturing { generations[id, default: 0] &+= 1 } else { capture(view, parked: parked, completion: completion) }
        }
        guard !view.redraw.givesNewTabFrame else { return }
        generations[id, default: 0] &+= 1
        let generation = generations[id]
        // The offscreen parking view keeps the page out of sight while it renders: not hidden, it draws there until
        // it painted at its parked size and while its cover is taken (`PageWebView+AwayDrawing`), so the next
        // handout shows a page already drawn; between those it reports hidden to Chromium, as a background tab.
        view.isHidden = false
        view.model.whenPainted { [weak self, weak view] in
            guard let self, let view, generations[id] == generation, parked(view) else { return }
            let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            view.redraw.rememberFrame(of: view, appearance: appearance, valid: { [weak self, weak view] in
                guard let self, let view else { return false }
                return generations[id] == generation && parked(view)
            }, completion: completion)
        }
    }

    /// `view` leaves the pool (handed out or dropped): its pending capture counts no more.
    public func forget(_ view: AgentPaneView) {
        generations[ObjectIdentifier(view)] = nil
        view.redraw.newTabFrameCaptureChanged = nil
    }
}
