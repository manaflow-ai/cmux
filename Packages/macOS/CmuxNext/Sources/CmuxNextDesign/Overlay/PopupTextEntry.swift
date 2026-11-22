public import AppKit

/// One editable field using the existing popup renderer, including its keyboard and dismissal behavior.
@MainActor
public final class PopupTextEntry {
    private var host: DeclarativePopupHost?
    public init() {}

    public func show(in view: NSView, at point: CGPoint, placeholder: String, submit: @escaping (String) -> Void) {
        guard let window = view.window else { return }
        host?.dismiss(reason: "replaced")
        let model = NativePopupModel(schemaVersion: 1, id: "text-entry", revision: 0,
                                     anchor: .init(left: 0, top: 0, right: 1, bottom: 1), side: .bottom, align: .start,
                                     width: 300, rows: [], search: .init(id: "text", value: "", placeholder: placeholder, submitOnReturn: true))
        let next = DeclarativePopupHost(webView: view, zoom: { 1 }, send: { [weak self] event in
            if event["type"] as? String == "dismiss" { self?.host = nil; return }
            guard event["type"] as? String == "submit", let value = event["value"] as? String else { return }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            self?.host?.dismiss(reason: "commit")
            submit(text)
        })
        host = next
        let anchor = window.convertToScreen(view.convert(NSRect(origin: point, size: NSSize(width: 1, height: 1)), to: nil))
        if next.show(model, screenAnchor: anchor, in: window)["shown"] as? Bool != true { host = nil }
    }
}
