import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension HomeCoreMapping {
    /// The owner's `widget` part (plans/cmux-next/chat-widgets-DESIGN.md section 3) as a Home
    /// widget, its props kept as JSON text for the app; nil without an app or a fallback (the
    /// caller then shows the part's plain text).
    static func widget(_ payload: JSONValue) -> ChatWidget? {
        guard let app = payload["app"]?.stringValue, !app.isEmpty,
              let fallback = payload["fallback"]?.stringValue, !fallback.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let props = payload["props"].flatMap { (try? encoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) } } ?? "{}"
        return ChatWidget(app: app, widget: payload["widget"]?.stringValue ?? "cmux.chat.widget/1", propsJSON: props,
                          fallback: fallback, url: payload["url"]?.stringValue)
    }
}
