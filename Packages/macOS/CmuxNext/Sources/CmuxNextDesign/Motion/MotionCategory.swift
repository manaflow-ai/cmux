public import Foundation

/// The area of the app an animation belongs to. Every animation asks its
/// category's ``MotionGate`` (`Motion.sidebar`, `Motion.tabs`, ...) for its
/// timing, so a person can turn each area off on its own
/// (`ui.animations.<category>` in cmux.json, Settings > Appearance > Motion),
/// and the master switch `ui.animations.enabled` turns every area off at once
/// (plans/cmux-next/motion-DESIGN.md).
///
/// A category that is off behaves as `ui.animationSpeed` "off" for its own
/// animations only: moves, fades and loops apply in one frame, and spinners
/// show their static glyph.
public nonisolated enum MotionCategory: String, Sendable, CaseIterable, Codable {
    /// Sidebar rows and groups: reorder, insert, remove, Move to Top, pin,
    /// collapse and expand, drag, the sidebar showing and hiding, the row
    /// hover buttons and title marquee.
    case sidebar
    /// The tab strip: tab open, close, reorder and drag, tab groups
    /// collapsing and expanding, strip scrolling, the tab title marquee.
    case tabs
    /// Panes and windows: split, close, zoom (Cmd-Shift-Enter), dividers,
    /// column and screen switches, drop zones, the focus ring and inactive
    /// dim, window and popup-window open and close, the launch mark.
    case panes
    /// Menus, popovers, the command palette, sheets, toasts, notices, find
    /// bars, cards (update, What's New), toolbars showing and hiding.
    case overlays
    /// Hover cards and tooltips.
    case hoverCards
    /// Home: the Chief chat transcript, bubbles, composer and the Home list
    /// (pin drag, rows).
    case home
    /// The agent cursor: its travel, ripples and trail.
    case cursor
    /// Spinners, pulses, progress lines and attention flashes. Off, a
    /// spinner shows its static glyph and a flash shows nothing.
    case indicators
    /// Hover and press highlights, focus fades, theme and color changes.
    case feedback
    /// The app's own web UI (agent chat, New Tab, Settings pages, Markdown):
    /// CSS transitions and animations. Off, pages get
    /// `prefers-reduced-motion` and every transition is 0 s.
    case web

    /// `ui.animations.<category>` in cmux.json.
    public var configKey: String { rawValue }
}
