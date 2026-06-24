public import AppKit

/// Marker protocol adopted by AppKit responders that participate in the Feed
/// right-sidebar keyboard-focus domain.
///
/// The app's window focus controller uses `responder is FeedKeyboardFocusResponder`
/// to decide whether keyboard focus currently lives in the Feed sidebar, so the
/// marker has to be visible to both the Feed UI views that adopt it (the inline
/// reply/answer editor) and the app-side focus controller that checks it. It
/// lives in `CmuxFeedUI` because the adopting view (`FeedInlineNativeTextView`)
/// is here; the app target imports `CmuxFeedUI` to perform the `is` check.
public protocol FeedKeyboardFocusResponder: AnyObject {}
