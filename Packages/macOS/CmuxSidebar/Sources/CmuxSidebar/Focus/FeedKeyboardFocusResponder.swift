/// Marker protocol adopted by feed keyboard-focus host responders so the
/// main-window focus controller can recognize feed-owned first responders with an
/// `is` check. Class-bound because it tags `NSResponder` subclasses.
public protocol FeedKeyboardFocusResponder: AnyObject {}
