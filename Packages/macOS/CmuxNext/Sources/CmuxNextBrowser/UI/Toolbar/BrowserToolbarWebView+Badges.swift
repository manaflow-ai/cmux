public import AppKit
public import CmuxNextDesign

/// The bookmark star's state (plans/cmux-next/bookmarks.md section 3): shown at the trailing end of
/// the omnibar while the page can be bookmarked and the user is not typing (the page hides it while
/// the field edits, as Chrome does).
public enum BookmarkStarState: Hashable, Sendable {
    /// No star: a page that cannot be bookmarked (blank, internal) or no host wiring.
    case hidden
    /// Hollow: the page is not bookmarked.
    case off
    /// Filled: the page is bookmarked in this tab's browser profile.
    case on
}

/// The tab's browser profile as the omnibar's small avatar.
public struct BrowserProfileBadge: Hashable, Sendable {
    /// An emoji, a letter, or an SF Symbol name.
    public var monogram: String
    public var color: GroupColor?
    /// The profile's name, for the tooltip and VoiceOver.
    public var name: String

    public init(monogram: String, color: GroupColor?, name: String) {
        self.monogram = monogram
        self.color = color
        self.name = name
    }
}

// The omnibar's trailing badges: browser focus mode, browser profile, machine, bookmark star. The
// page draws them; the host says what they show and opens their menus at their anchors.
extension BrowserToolbarWebView {
    /// Sets the star for the page on screen. The host recomputes it when the URL or the bookmarks change.
    public func setBookmarkStar(_ state: BookmarkStarState) { bookmarkStar = state }

    public var bookmarkStarState: BookmarkStarState { bookmarkStar }

    /// The star's anchor, to open the edit bubble from a keyboard or palette command (nil while hidden).
    public var bookmarkStarAnchor: NSView? { bookmarkStar == .hidden ? nil : anchor("star") }

    /// The machine whose localhost this tab sees, as a subtle chip; nil hides it
    /// (plans/cmux-next/remote-localhost.md section 6).
    public func setMachineBadge(_ text: String?, help: String?) {
        let next = text.map { (text: $0, help: help ?? $0) }
        // Called on every render of the chrome; the same badge pushes nothing.
        guard next?.text != shownMachineBadge?.text || next?.help != shownMachineBadge?.help else { return }
        shownMachineBadge = next
        setNeedsPush()
    }

    /// The tab's browser profile as a small avatar; nil hides it (one profile, or an incognito tab).
    public func setProfileBadge(_ badge: BrowserProfileBadge?) {
        guard badge != shownProfileBadge else { return }
        shownProfileBadge = badge
        setNeedsPush()
    }

    /// The badge's tooltip shown now, for diagnostics (`debug.browser`).
    public var profileBadgeName: String? { shownProfileBadge.map { BrowserProfileStrings.badgeHelp($0.name) } }

    /// Browser focus mode's badge: nil hides it, else "Focus Mode" or, once the first Escape armed
    /// the exit, "Esc again to exit". The page fades it in and out through its motion gate.
    public func setFocusModeBadge(armed: Bool?) {
        focusModeBadge = armed.map { $0 ? Strings.focusModeArmed : Strings.focusModeActive }
    }

    /// Whether the focus mode badge shows (tests, diagnostics).
    public var showsFocusModeBadge: Bool { focusModeBadge != nil }
    /// The focus mode badge's text (tests, diagnostics).
    public var focusModeBadgeText: String? { focusModeBadge }
}

/// What automation reads about the omnibar (`debug.omnibar`), as the toolbar page reported it.
public struct OmnibarDebugSnapshot: Sendable, Equatable {
    public var phase: String
    public var hasFocus: Bool
    /// The focused field shows the steady-state (elided) URL.
    public var elided: Bool
    /// What the field shows, and its selection (UTF-16).
    public var text: String
    public var selection: NSRange?
    /// The page's input: the same text (the page is the only writer of its input).
    public var fieldText: String
    public var fieldSelection: NSRange?
    /// The web view has the keys.
    public var fieldEditorActive: Bool
    public var rows: [String]
    public var highlighted: Int?
    /// What Copy would put on the pasteboard now; the page answers Copy itself (nil here).
    public var copyText: String?
}

/// Where the suggestion card is, as automation reads it (`debug.omnibar`).
public struct OmnibarDebugCard: Sendable, Equatable {
    /// The card is its own child panel of the browser window (always, since the card is a page).
    public var paneLayer: Bool
    public var cardInWindow: NSRect
    public var barInWindow: NSRect
    public var rowKinds: [String]

    /// Flush under the bar and as wide as it.
    public var isFlushUnderBar: Bool {
        cardInWindow.maxY == barInWindow.minY && cardInWindow.minX == barInWindow.minX && cardInWindow.width == barInWindow.width
    }

    /// Flush above the bar (`browser.toolbarPosition` bottom) and as wide as it.
    public var isFlushAboveBar: Bool {
        cardInWindow.minY == barInWindow.maxY && cardInWindow.minX == barInWindow.minX && cardInWindow.width == barInWindow.width
    }
}

extension BrowserToolbarWebView {
    public var debugSnapshot: OmnibarDebugSnapshot {
        let active = content.map { window?.firstResponder === $0.focusView } ?? false
        return OmnibarDebugSnapshot(
            phase: status.phase, hasFocus: status.isEditing, elided: status.elided, text: status.text, selection: status.selection,
            fieldText: status.text, fieldSelection: status.selection, fieldEditorActive: active, rows: status.rows,
            highlighted: status.highlighted, copyText: nil
        )
    }

    /// The field's frame in window coordinates (the text area the page reported).
    public var debugFieldFrameInWindow: NSRect {
        guard let text = anchor("text") ?? anchor("omnibar") else { return .zero }
        return text.convert(text.bounds, to: nil)
    }

    /// The web view's key state (`debug.omnibar` `editor`).
    public var debugEditorInfo: [String: String] {
        guard let content else { return [:] }
        return [
            "window_key": String(window?.isKeyWindow ?? false),
            "first_responder": String(window?.firstResponder === content.focusView),
            "editor_class": "BrowserToolbarWebView",
        ]
    }

    /// The shown card, or nil when it is closed.
    public var debugCard: OmnibarDebugCard? {
        guard popup.isVisible, let window, let bar = anchor("omnibar"), let card = popup.cardRectInScreen else { return nil }
        return OmnibarDebugCard(paneLayer: false, cardInWindow: window.convertFromScreen(card), barInWindow: bar.convert(bar.bounds, to: nil),
                                rowKinds: popup.rowKinds)
    }

    /// Presses suggestion row `index` as a click does. False when the card has no such row.
    public func debugPressRow(_ index: Int) -> Bool {
        guard popup.isVisible, popup.rowKinds.indices.contains(index) else { return false }
        send(BrowserToolbarHostEvent.rowClick(index, shown: popup.shownRow(index), meta: false, shift: false, alt: false))
        return true
    }
}
