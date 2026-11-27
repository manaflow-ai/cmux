public import AppKit

/// A child panel cmux makes for a main window, which joins a full screen Space only with that window
/// (``ChildWindowSpaces``): the overlay host panel, popups, hover cards, the palette, editors, the notifications panel,
/// divider catchers. Opt-in by the class that makes the panel, so a window cmux does not make (a Chromium page window,
/// one of Chromium's own panels) keeps its own collection behavior whatever its class.
public protocol FullScreenFollowingChild: NSWindow {}
