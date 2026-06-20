public import WebKit
import Observation

/// Records which browser `WKWebView` owns a given window field editor
/// (`NSTextView` with `isFieldEditor == true`), so the app's first-responder
/// routing can recover the owning web view from a bare field-editor responder.
///
/// This retires the top-level `cmuxFieldEditorOwningWebViewAssociationKey`
/// global var plus its `CmuxFieldEditorOwningWebViewBox` wrapper that the app
/// delegate used to thread through `objc_setAssociatedObject` on each field
/// editor. A process-global association key plus a hand-rolled weak box is a
/// singleton in disguise; the refactor de-singletonizes it into a real
/// `@MainActor` instance the composition root holds and injects.
///
/// Lifecycle is byte-faithful to the associated-object behavior it replaces:
///
/// - The backing store is `NSMapTable.weakToWeakObjects()`, so a field-editor
///   key is dropped automatically when the field editor deallocates (the same
///   moment the `OBJC_ASSOCIATION_RETAIN_NONATOMIC` association was freed), and
///   a value is nilled automatically when its web view deallocates (the same
///   moment the box's `weak var webView` went `nil`).
/// - ``owningWebView(forFieldEditor:)`` mirrors the former lazy cleanup: when a
///   tracked web view has gone away it removes the now-dangling field-editor
///   entry before returning `nil`, exactly as the box read path re-set the
///   association to `nil`.
///
/// `@MainActor` because every reader and writer is a main-thread first-responder
/// path (`cmux_makeFirstResponder`, the omnibar field-editor resolver). State
/// lives where its callers live; no actor or lock is warranted.
@MainActor
@Observable
public final class BrowserFieldEditorOwnershipRegistry {
    @ObservationIgnored
    private let ownersByFieldEditor: NSMapTable<NSTextView, WKWebView> =
        .weakToWeakObjects()

    /// Creates an empty registry.
    public init() {}

    /// Records `webView` as the owner of `fieldEditor`, or clears the recorded
    /// owner when `webView` is `nil`.
    ///
    /// Matches the former `cmuxTrackFieldEditor(_:owningWebView:)`: a non-`nil`
    /// web view stores a weak association; a `nil` web view removes it.
    ///
    /// - Parameters:
    ///   - fieldEditor: The window field editor whose owner is being recorded.
    ///   - webView: The browser web view that owns the field editor, or `nil`
    ///     to clear any recorded owner.
    public func setOwningWebView(_ webView: WKWebView?, forFieldEditor fieldEditor: NSTextView) {
        if let webView {
            ownersByFieldEditor.setObject(webView, forKey: fieldEditor)
        } else {
            ownersByFieldEditor.removeObject(forKey: fieldEditor)
        }
    }

    /// Returns the web view recorded as owning `fieldEditor`, or `nil` when none
    /// is recorded or the recorded web view has since deallocated.
    ///
    /// When the recorded web view is gone the stale field-editor entry is
    /// removed before returning, matching the former box read path that re-set
    /// the dangling association to `nil`.
    ///
    /// - Parameter fieldEditor: The window field editor to look up.
    /// - Returns: The owning web view, if still live.
    public func owningWebView(forFieldEditor fieldEditor: NSTextView) -> WKWebView? {
        guard let webView = ownersByFieldEditor.object(forKey: fieldEditor) else {
            // Match the former lazy clear: drop the now-dangling entry so a dead
            // web view leaves nothing tracked for this field editor.
            ownersByFieldEditor.removeObject(forKey: fieldEditor)
            return nil
        }
        return webView
    }
}
