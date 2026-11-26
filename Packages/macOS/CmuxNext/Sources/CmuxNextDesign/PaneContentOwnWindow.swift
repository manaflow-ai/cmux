public import AppKit

/// Pane content whose pixels come from a window of its own over its pane (a cmux page shown on the Chromium engine:
/// Chromium's GPU process draws it into a child window of the cmux window), not from a layer in the pane's tree.
///
/// A pane's move at a split, a close, a zoom or an unzoom (`PaneCommitMotion`) cuts its content with the pane's moving
/// clip, a layer: a child window is not under that clip. Its window took the pane's new frame in the frame that shows
/// the change, over the panes the move still shows under the pane, with nothing of the pane's ground under its
/// see-through page (Lawrence 2026-11-23 film: a Markdown page zoomed beside a terminal showed the terminal's text
/// through the page through the whole zoom and unzoom, and its text wrapped again mid-move). So such content does not
/// ride (``NSView/paneRidesCommitMotion``): the change shows in one frame, as with the pane animations off.
@MainActor
public protocol PaneContentOwnWindow: NSView {
    /// Whether it draws in its own window now (false: a WebKit page, or a page that shows in its view's layer).
    var drawsInOwnWindow: Bool { get }
}
