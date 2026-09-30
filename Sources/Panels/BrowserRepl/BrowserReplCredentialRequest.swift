import AppKit
import WebKit

/// The native half of `sites.browserAuth.request`, driver method `auth.request`
/// (docs/browser-repl/site-tools.md, "Secure sign-in").
///
/// Shows a sheet on the browser pane's window that names the page's origin
/// and asks for the fields the agent described. On Fill it runs the bundle's
/// `sites/auth-fill.js` in the agent content world of the frame that holds
/// the fields, passing the typed values as call arguments. The REPL receives
/// a status and never a value. The REPL is untrusted, so every parameter is
/// validated here again.
@MainActor
enum BrowserReplCredentialRequest {
    struct Field {
        let id: String
        let label: String
        let type: String
        let autocomplete: String?
        let required: Bool
        let marker: String
    }

    static let fieldTypes: Set<String> = ["text", "email", "password", "tel", "number", "url"]
    static let defaultTimeoutMilliseconds = 110_000
    static let maxTimeoutMilliseconds = 600_000

    static func run(
        webView: WKWebView,
        frameInfo: WKFrameInfo?,
        params: [String: Any],
        fillSource: String?
    ) async -> [String: Any] {
        guard let fillSource else { return ["status": "unavailable"] }
        guard let origin = params["origin"] as? String,
              let fields = parseFields(params["fields"]) else {
            return ["status": "locator_invalid"]
        }
        guard currentOrigin(webView) == origin else { return ["status": "origin_changed"] }
        guard let window = hostWindow(for: webView) else { return ["status": "unavailable"] }
        let requested = (params["timeoutMs"] as? NSNumber)?.intValue ?? defaultTimeoutMilliseconds
        let timeout = Duration.milliseconds(min(max(requested, 1_000), maxTimeoutMilliseconds))

        let sheet = BrowserReplCredentialSheet(origin: origin, fields: fields)
        let answer = await sheet.present(on: window, timeout: timeout)
        guard case .filled(let values) = answer else {
            return ["status": answer == .expired ? "expired" : "cancelled"]
        }
        guard currentOrigin(webView) == origin else { return ["status": "origin_changed"] }
        let arguments: [String: Any] = [
            "__fields": fields.map { ["id": $0.id, "marker": $0.marker] },
            "__values": values,
        ]
        do {
            let result = try await webView.callAsyncJavaScript(
                fillSource,
                arguments: arguments,
                in: frameInfo,
                contentWorld: BrowserReplAgentWorld.world
            )
            let status = (result as? [String: Any])?["status"] as? String ?? "page_changed"
            return ["status": status]
        } catch {
            return ["status": "page_changed"]
        }
    }

    /// Fields as the REPL sent them, or nil when any is malformed.
    static func parseFields(_ raw: Any?) -> [Field]? {
        guard let list = raw as? [[String: Any]], (1...6).contains(list.count) else { return nil }
        var seen = Set<String>()
        var fields: [Field] = []
        for item in list {
            guard let id = item["id"] as? String, isToken(id, maxLength: 40), seen.insert(id).inserted,
                  let label = item["label"] as? String,
                  !label.trimmingCharacters(in: .whitespaces).isEmpty,
                  label.count <= 60,
                  label.rangeOfCharacter(from: .newlines) == nil,
                  let type = item["type"] as? String, fieldTypes.contains(type),
                  let marker = item["marker"] as? String, isToken(marker, maxLength: 80) else {
                return nil
            }
            fields.append(Field(
                id: id,
                label: label.trimmingCharacters(in: .whitespaces),
                type: type,
                autocomplete: item["autocomplete"] as? String,
                required: item["required"] as? Bool ?? true,
                marker: marker
            ))
        }
        return fields
    }

    private static func isToken(_ value: String, maxLength: Int) -> Bool {
        !value.isEmpty && value.count <= maxLength
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// scheme://host[:port] of the tab's main frame.
    static func currentOrigin(_ webView: WKWebView) -> String? {
        guard let url = webView.url, let scheme = url.scheme, let host = url.host else { return nil }
        let defaultPort = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        if let port = url.port, !defaultPort { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// The window that shows the tab, or, when the REPL renders the tab in an
    /// off-screen window, the main cmux window.
    private static func hostWindow(for webView: WKWebView) -> NSWindow? {
        if let window = webView.window, window.isVisible,
           NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            return window
        }
        return NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain }
    }
}

/// The credential sheet: the origin, a note that the agent never sees the
/// values, one field per requested credential, Cancel and Fill.
@MainActor
final class BrowserReplCredentialSheet: NSObject {
    enum Answer: Equatable {
        case filled([String: String])
        case cancelled
        case expired
    }

    private let fields: [BrowserReplCredentialRequest.Field]
    private let panel: NSWindow
    private var inputs: [NSTextField] = []
    private var continuation: CheckedContinuation<Answer, Never>?
    private var timer: Task<Void, Never>?
    private weak var parent: NSWindow?

    init(origin: String, fields: [BrowserReplCredentialRequest.Field]) {
        self.fields = fields
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        build(origin: origin)
    }

    func present(on window: NSWindow, timeout: Duration) async -> Answer {
        parent = window
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            window.beginSheet(panel)
            NSApp.requestUserAttention(.informationalRequest)
            panel.makeFirstResponder(inputs.first)
            timer = Task { [weak self] in
                try? await ContinuousClock().sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.expired)
            }
        }
    }

    private func build(origin: String) {
        let title = NSTextField(labelWithString: String(
            format: String(localized: "browser.repl.auth.title", defaultValue: "Sign in to %@"),
            origin
        ))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        let note = NSTextField(wrappingLabelWithString: String(
            localized: "browser.repl.auth.message",
            defaultValue: "An agent asked cmux to fill this sign-in form. What you type goes only into the page; the agent never sees it."
        ))
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        for field in fields {
            let label = NSTextField(labelWithString: field.label)
            label.alignment = .right
            let input: NSTextField = field.type == "password" ? NSSecureTextField() : NSTextField()
            input.contentType = Self.contentType(for: field)
            input.widthAnchor.constraint(equalToConstant: 260).isActive = true
            inputs.append(input)
            grid.addRow(with: [label, input])
        }
        for (index, input) in inputs.enumerated() {
            input.nextKeyView = index + 1 < inputs.count ? inputs[index + 1] : inputs.first
        }

        let cancel = NSButton(
            title: String(localized: "browser.repl.auth.cancel", defaultValue: "Cancel"),
            target: self,
            action: #selector(cancelPressed)
        )
        cancel.keyEquivalent = "\u{1b}"
        let fill = NSButton(
            title: String(localized: "browser.repl.auth.fill", defaultValue: "Fill"),
            target: self,
            action: #selector(fillPressed)
        )
        fill.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, fill])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, note, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(16, after: grid)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
    }

    private static func contentType(for field: BrowserReplCredentialRequest.Field) -> NSTextContentType? {
        switch field.autocomplete {
        case "one-time-code": return .oneTimeCode
        case "current-password", "new-password": return .password
        case "username", "email": return .username
        default: return field.type == "password" ? .password : nil
        }
    }

    @objc private func cancelPressed() {
        finish(.cancelled)
    }

    @objc private func fillPressed() {
        var values: [String: String] = [:]
        for (field, input) in zip(fields, inputs) {
            if field.required && input.stringValue.isEmpty {
                NSSound.beep()
                panel.makeFirstResponder(input)
                return
            }
            values[field.id] = input.stringValue
        }
        finish(.filled(values))
    }

    private func finish(_ answer: Answer) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        for input in inputs { input.stringValue = "" }
        parent?.endSheet(panel)
        continuation.resume(returning: answer)
    }
}
