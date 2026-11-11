public import CmuxHomeCore

/// Runs chat widgets for the Home transcript (plans/cmux-next/chat-widgets-DESIGN.md).
///
/// The transcript asks for the current ``HomeWidgetSnapshot`` of each widget part it shows,
/// keyed `<message id>#<part index>`, and sends clicks back. The Mac app implements it with its
/// app host: it mounts the part's app (`cmux.chat.widget/1`) with the part's props and maps the
/// scene the script returns. A host without one passes none, and widgets show their fallback
/// text.
///
/// Mounts live while some transcript keeps their key (``keep(_:owner:)``), not only while the row
/// is on screen, so a widget's page and signals survive scrolling.
///
/// ```swift
/// final class FixedWidgets: HomeWidgetHosting {
///     func snapshot(for key: String, widget: ChatWidget) -> HomeWidgetSnapshot? {
///         HomeWidgetSnapshot(items: [.text(widget.fallback)])
///     }
///     func tap(key: String, node: String) {}
///     func keep(_ keys: Set<String>, owner: ObjectIdentifier) {}
///     func changes() -> AsyncStream<String> { AsyncStream { _ in } }
/// }
/// ```
@MainActor
public protocol HomeWidgetHosting: AnyObject {
    /// The widget's snapshot now, mounting it on first use; nil while it loads, when its app is
    /// not installed or when it failed (the transcript then draws the fallback).
    ///
    /// - Parameters:
    ///   - key: `<message id>#<part index>`, stable for the part's life (the storage key too).
    ///   - widget: the part.
    func snapshot(for key: String, widget: ChatWidget) -> HomeWidgetSnapshot?

    /// A click on the item drawn for scene node `node` of widget `key`.
    func tap(key: String, node: String)

    /// The widget keys one transcript (`owner`) shows; keys no transcript keeps are unmounted.
    /// An empty set releases the owner.
    func keep(_ keys: Set<String>, owner: ObjectIdentifier)

    /// The key of each widget whose snapshot changed, as it changes.
    func changes() -> AsyncStream<String>
}
