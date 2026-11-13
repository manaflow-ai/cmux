import AppKit
import CmuxNextCompat

/// What a key-window change does to hover (`PointerHover`).
///
/// A window that becomes or resigns key recomputes its key-window targets at once. The other
/// targets do not read the key: for them a key change matters only as a sign that the window
/// order changed (another window came to the front over a still pointer, and no exit arrives).
/// So the resign and the become of one key change are read together:
///
/// - The key moved inside one window, between it and a Chromium page window of it (`home(of:)`):
///   no notice recomputes at once. The window is recomputed one time when that pass of the run
///   loop ends, for all such notices of the pass. A workspace switch between two browser tabs
///   makes two such changes, 4 notices, and each notice used to ask the window server for the
///   topmost window at the pointer once for each target under it (a synchronous round trip; 39
///   main-thread samples of a 20 switch recording). The one recompute stays because the change
///   is not only a key change: the page that leaves is ordered out with it, which uncovers what
///   it covered under a still pointer, and the switch that caused it hid and showed views that
///   do not all report it. It runs after them: in their pass, or in the pass that starts at once
///   when the notices came from a run loop observer at the end of one (the hover is then right
///   one frame after the switch at most). A panel, a sheet or a popup of the window is not
///   inside it: it can show over the pointer as it takes the key.
/// - The key moved to another window, or to or from a page window whose window is not known:
///   both windows are refreshed, as each notice did before.
/// - A window resigned and no window became key by the end of that pass of the run loop (another
///   app came to the front): that window is refreshed then, once, in that pass (a page of a
///   window that is recomputed then is in that recompute). A become in a later pass refreshes
///   its window as before.
///
/// Chromium does the same job with one synthesized mouse move after a change, coalesced
/// (`Widget::SynthesizeMouseMoveEvent`), not one hit test for each view at each notice.
///
/// The notices arrive through `MainActorObservation` on the main queue, never a selector: AppKit
/// may post these off the main thread, and a selector into this main-actor class trapped there
/// (#18771). A post on the main thread runs the handler inline, so key changes and closes keep
/// their synchronous order.
@MainActor
final class KeyWindowObserver {
    /// A Chromium page window and the window it was a child of, both weak.
    private struct PageHome {
        weak var page: NSWindow?
        weak var window: NSWindow?
    }

    private var observations: [MainActorObservation] = []
    /// The window that resigned key, while no window became key after it.
    private weak var resigned: NSWindow?
    /// `resigned`'s home when it resigned (`home(of:)`).
    private weak var resignedHome: NSWindow?
    /// The window that the key moved inside in this pass of the run loop (between it and a page
    /// of it), not recomputed yet.
    private weak var moved: NSWindow?
    /// The end-of-pass read of `resigned` and `moved` is queued.
    private var settles = false
    /// The window each Chromium page window was a child of when a key change last saw it with a
    /// parent, by the page window's identifier. It keeps no window alive, a window that closes
    /// leaves it, and each key change that sees the page with a parent writes the entry again.
    private var homes: [ObjectIdentifier: PageHome] = [:]

    init() {
        let window: @MainActor (Notification) -> NSWindow? = { $0.object as? NSWindow }
        observations.append(MainActorObservation(NSWindow.didResignKeyNotification, read: window) { [weak self] in
            self?.resign($0)
        })
        observations.append(MainActorObservation(NSWindow.didBecomeKeyNotification, read: window) { [weak self] in
            self?.become($0)
        })
        observations.append(MainActorObservation(NSWindow.willCloseNotification, read: window) { [weak self] in
            guard let closed = $0 else { return }
            self?.closed(closed)
            #if DEBUG || CMUX_BENCH_HOOKS
            // A closed window's synthesized pointer must not pass to a new window
            // that reuses its address.
            PointerHover.debugPointers[ObjectIdentifier(closed)] = nil
            #endif
        })
    }

    /// Where the key goes is not known yet: the become of this change posts after the resign, in
    /// this pass, or no window of the app takes the key.
    private func resign(_ window: NSWindow?) {
        // A window in deallocation is no window here: a weak reference to it aborts the process
        // (a view that leaves a dying window can post its key notice).
        guard let window, !window.isBeingDeallocated else { return }
        PointerHover.keyChanged(in: window)
        // A second resign with no become between them: the first window's key left the app's windows.
        if let earlier = resigned, earlier !== window { PointerHover.refresh(in: earlier) }
        resigned = window
        resignedHome = home(of: window)
        settleWhenThePassEnds()
    }

    private func become(_ window: NSWindow?) {
        // A window in deallocation is no window here either, and the resign before it stays a
        // resign with no become: that window is recomputed when the pass ends.
        if let window, window.isBeingDeallocated { return }
        let (old, oldHome) = (resigned, resignedHome)
        (resigned, resignedHome) = (nil, nil)
        guard let window else { return }
        PointerHover.keyChanged(in: window)
        let newHome = home(of: window)
        if let old {
            if let oldHome, oldHome === newHome { return movedInside(oldHome) }
            PointerHover.refresh(in: old)
        }
        PointerHover.refresh(in: window)
    }

    /// The key moved between `home` and a page of it: `home` is recomputed one time when this
    /// pass ends, after what came with the change (the page ordered out or in, the views that a
    /// switch hid and showed), for every such move of the pass.
    private func movedInside(_ home: NSWindow) {
        // A second window's change in one pass: the first is recomputed now.
        if let earlier = moved, earlier !== home { PointerHover.refresh(in: earlier) }
        moved = home
        settleWhenThePassEnds()
    }

    private func settleWhenThePassEnds() {
        guard !settles else { return }
        settles = true
        // A block of the run loop, not a timer and not a job of the main queue: it runs in the
        // pass that the notice is in (the pass that starts now, when the notice came between two).
        MainRunLoopBlock.perform { [weak self] in self?.settle() }
    }

    /// The window `window` is a part of, for the pointer: itself, or for a Chromium page window
    /// (`CefNSWindow`) the window it is the content of. That is its parent; a page with no parent
    /// (a page that leaves at a workspace switch is ordered out, which takes it from its parent)
    /// is the content of the window a key change last saw it in (`homes`). Nil: a page window
    /// that no key change saw with a parent. The caller then recomputes the hover; nothing is
    /// guessed from the main window.
    private func home(of window: NSWindow) -> NSWindow? {
        guard let pageClass = NSClassFromString("CefNSWindow"), window.isKind(of: pageClass) else { return window }
        let key = ObjectIdentifier(window)
        guard var current = window.parent else { return knownHome(of: window) }
        // A page in a page at most; the bound only stops a cycle.
        for _ in 0..<4 {
            guard current.isKind(of: pageClass) else {
                // A parent in deallocation takes no weak reference: the page's window is not known.
                guard !current.isBeingDeallocated else { break }
                if homes.count > 32 { homes = homes.filter { $0.value.page != nil && $0.value.window != nil } }
                homes[key] = PageHome(page: window, window: current)
                return current
            }
            guard let parent = current.parent else { break }
            current = parent
        }
        homes[key] = nil
        return nil
    }

    /// The window `page` was a child of when a key change last saw it with a parent, while both
    /// are open.
    func knownHome(of page: NSWindow) -> NSWindow? {
        guard let entry = homes[ObjectIdentifier(page)] else { return nil }
        // The identifier of a freed window can come again with a new window.
        guard entry.page === page, let window = entry.window else {
            homes[ObjectIdentifier(page)] = nil
            return nil
        }
        return window
    }

    /// `window` closes: as a page it leaves `homes`, and so do the pages that were its. A closed
    /// window has no hover left to recompute for a key change inside it.
    private func closed(_ window: NSWindow) {
        homes[ObjectIdentifier(window)] = nil
        homes = homes.filter { $0.value.window !== window }
        if moved === window { moved = nil }
    }

    /// The pass that had a key notice ends. A window that the key moved inside is recomputed one
    /// time. A resign with no become since: the key left the app's windows, and that window is
    /// recomputed, unless it is the window recomputed just now or a page of it (a recompute reads
    /// every target that hovers and the window's targets under the pointer).
    private func settle() {
        settles = false
        let (lone, loneHome, family) = (resigned, resignedHome, moved)
        (resigned, resignedHome, moved) = (nil, nil, nil)
        if let family { PointerHover.refresh(in: family) }
        if let lone, family == nil || loneHome !== family { PointerHover.refresh(in: lone) }
    }
}
