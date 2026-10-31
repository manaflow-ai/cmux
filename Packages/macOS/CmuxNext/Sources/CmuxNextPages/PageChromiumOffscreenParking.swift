public import AppKit

/// A view that parks prewarmed pages far outside its window's content and is transparent only to
/// keep them out of sight (the New Tab spare's parking). Its alpha does not hide a Chromium page
/// in it (``PageWebView/setChromiumVisibility(_:)``): the page must draw its first frame while
/// parked, so that adopting it shows a page that already painted. Hidden by its alpha, a parked
/// Chromium spare never painted, and each Cmd-T waited for the pane's 500 ms paint-hold limit.
@MainActor
public protocol PageChromiumOffscreenParking: NSView {}
