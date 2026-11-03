public import AppKit
import ObjectiveC

/// A window's content view whose subtree takes AppKit's key-state walk only when the keyboard enters or leaves the
/// window's family (``WindowKeyStateWalk``).
///
/// On every key change AppKit walks the old and the new key window's whole view trees (`_windowChangedKeyState`), and
/// every button, text field and split view lays out and redraws for it. A cmux window's family (its Chromium page
/// windows, popups and sheets) never makes it look inactive (``WindowMaterialView/looksInactive(appActive:familyHoldsKey:familyHeldKey:)``),
/// and a page window never becomes main: when the keyboard moves between the window and its own page window (Cmd-T's
/// New Tab page, a click into a browser tab), nothing in the content changes, but the walk cost 11 ms of layout and
/// 5 ms of display in the key's commit (NEWTAB DEVTOOLS FRAMES, profile ndf-kt-prof-head0). As Chrome keeps its window
/// key while focus moves between its views, the content walks only when the family's key state flips, once per turn,
/// before that pass's commit.
open class FamilyKeyStateView: NSView {
    /// When the content walks (tests replace the environment).
    var keyStateWalk = WindowKeyStateWalk()

    @objc(_windowChangedKeyState)
    func familyWindowChangedKeyState() {
        guard window != nil else { return WindowKeyStateWalk.walk(self) }
        keyStateWalk.keyStateChanged(of: self) { [weak self] in self.map(WindowKeyStateWalk.walk) }
    }
}

/// Runs AppKit's key-state walk of one window's content only when the window's family gains or loses the keyboard.
///
/// The decision reads the key window after the notices of the key change have posted (between a resign and the next
/// become no window is key), as ``WindowKeyFamily`` does, on the next main run loop block: before that pass's commit,
/// so a walk that runs lands in the same frame as AppKit's own key-state redraw of the titlebar.
@MainActor
final class WindowKeyStateWalk {
    private let environment: WindowKeyEnvironment
    /// The content view whose window's family is read at the check.
    private weak var content: NSView?
    /// The family's key state the content last walked for; nil before the first walk.
    private var walkedHoldsKey: Bool?
    /// The walk of the notices of this turn, run at its check when the state flipped.
    private var pending: (@MainActor () -> Void)?
    /// Walks run and checks that walked nothing (tests).
    private(set) var walks = 0
    private(set) var skipped = 0

    init(environment: WindowKeyEnvironment = .live) {
        self.environment = environment
    }

    /// AppKit sent the content a key-state notice: `walk` (AppKit's own walk of the content) runs at this turn's check
    /// if the family's key state differs from the one the content last walked for.
    func keyStateChanged(of content: NSView, walk: @escaping @MainActor () -> Void) {
        self.content = content
        let scheduled = pending != nil
        pending = walk
        guard !scheduled else { return }
        environment.nextTurn { [weak self] in self?.check() }
    }

    private func check() {
        guard let walk = pending else { return }
        pending = nil
        guard let window = content?.window else { return walk() }
        let key = environment.keyWindow()
        // A page window Chromium made key before the fork placed it as this window's child acts for the main window.
        let parentlessPage = key.map { $0.parent == nil && $0.sheetParent == nil && Self.isChromiumPageWindow($0) } ?? false
        let holds = environment.isAppActive()
            && (WindowMaterialView.family(of: window, holds: key, owner: { $0.parent ?? $0.sheetParent }) || (parentlessPage && window.isMainWindow))
        guard holds != walkedHoldsKey else {
            skipped += 1
            return
        }
        walkedHoldsKey = holds
        walks += 1
        walk()
    }

    /// `CefNSWindow`: a Chromium page window.
    private static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        NSClassFromString("CefNSWindow").map { window.isKind(of: $0) } ?? false
    }

    /// AppKit's own key-state walk of `view`'s subtree (`NSView`'s implementation).
    static func walk(_ view: NSView) {
        typealias Method = @convention(c) (NSView, Selector) -> Void
        let selector = NSSelectorFromString("_windowChangedKeyState") // crash-allow: AppKit private selector, called only when NSView responds to it
        guard NSView.instancesRespond(to: selector), let implementation = class_getMethodImplementation(NSView.self, selector) else { return }
        unsafeBitCast(implementation, to: Method.self)(view, selector)
    }
}
