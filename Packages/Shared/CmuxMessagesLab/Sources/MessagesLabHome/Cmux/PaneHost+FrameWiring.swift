import AppKit

// cmux: Host.swift's wiring from MessagesLab ced183d (main ac069b9) for the pane host.
extension ChatController {
    /// One transcript width pass per display frame in a divider drag or live resize (709250d),
    /// the field glass's press light and release flash (96c05f0, 83c04f7), and the scroller's
    /// animated track-click page that the selection highlight follows (MessagesLab's
    /// TranscriptScrollView.page and WindowView.pageFollowers).
    ///
    /// Not ported: the launch context-menu pre-warm (8ef0ac9, Host.swift `warmMenu`). It opens and
    /// cancels a real context menu of the newest incoming bubble from a synthesized right-mouse-down.
    /// In the cmux-next app that would run once per Home tab, in a window that may not be key,
    /// can post menu-open and menu-close accessibility notifications that VoiceOver speaks, and
    /// runs a menu tracking loop that takes the keyboard while the user may be typing in another
    /// pane. MessagesLab removes it for the same reasons (2026-10-09). Home has no pre-warm.
    func installFrameAndPressWiring(_ demo: MessagesWindowView) {
        if ProcessInfo.processInfo.environment["MLAB_EXP"] != "everychange" {
            demo.widthFrameScheduler = { [weak self] f in if let self { self.nextFrame(f) } else { f() } }
            demo.onWidthPass = { [weak self] in self?.host.placeNativeViews() }
        }
        demo.pageFollowers = [host.selectionHost.root]
        (host.scrollView.verticalScroller as? SequenceScroller)?.onPage = { [weak self] dir in
            // One page, animated as Messages does (TranscriptScrollView.page).
            self?.host.scrollView.page(dir, event: NSApp.currentEvent)
        }
        let field = demo.compose.textView.view
        field.onPress = { [weak self] e in self?.host.fieldChrome.pressLight(e) }
        field.onRelease = { [weak self] e in self?.host.fieldChrome.releaseFlash(e) }
    }
}
