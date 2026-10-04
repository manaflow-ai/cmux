import AppKit
import CmuxBrowser
import WebKit

/// The native half of `sites.browserAuth.request`, driver method `auth.request`
/// (docs/browser-repl/site-tools.md, "Secure sign-in").
///
/// Shows a sheet on the browser pane's window that names the origin of the
/// frame that holds the fields (WebKit's record of it, not the main frame's
/// and not anything the REPL sent) and asks for the fields the agent
/// described. On Fill it runs the bundle's `sites/auth-fill.js` in the
/// driver's own content world of that frame, which fills only password,
/// username and one-time-code inputs, passing the typed values as call
/// arguments. The REPL receives a status and never a value. The REPL is
/// untrusted, so every parameter is validated here again. The page itself,
/// and code the agent runs in the page, can read a filled field like any
/// other, and the sheet says so.
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

    /// - Parameter requester: The tab and workspace whose agent asks, shown
    ///   on the sheet: the sheet appears on whichever cmux window the user
    ///   works in, which may show another workspace.
    /// - Parameter stillAllowed: Whether the session that asks still drives
    ///   the tab; checked again after the user's Fill, before anything is
    ///   filled.
    static func run(
        webView: WKWebView,
        frameInfo: WKFrameInfo?,
        params: [String: Any],
        fillSource: String?,
        requester: (tab: String, workspace: String),
        stillAllowed: @MainActor () -> Bool
    ) async -> [String: Any] {
        guard let fillSource else { return ["status": "unavailable"] }
        guard let origin = params["origin"] as? String,
              let fields = parseFields(params["fields"]) else {
            return ["status": "locator_invalid"]
        }
        guard currentOrigin(webView) == origin else { return ["status": "origin_changed"] }
        // The frame that receives the values, by WebKit's own record.
        guard let fieldsOrigin = frameOrigin(frameInfo, webView) else { return ["status": "page_changed"] }
        guard let window = hostWindow(for: webView) else { return ["status": "unavailable"] }
        let requested = (params["timeoutMs"] as? NSNumber)?.intValue ?? defaultTimeoutMilliseconds
        let timeout = Duration.milliseconds(min(max(requested, 1_000), maxTimeoutMilliseconds))

        let sheet = BrowserReplCredentialSheet(origin: fieldsOrigin, pageOrigin: origin, fields: fields, requester: requester)
        let answer = await sheet.present(on: window, timeout: timeout)
        guard case .filled(let values) = answer else {
            return ["status": answer == .expired ? "expired" : "cancelled"]
        }
        // The call, or the session, may have ended while the sheet was up:
        // then the sheet was taken down and nothing is filled.
        guard !Task.isCancelled, stillAllowed() else { return ["status": "cancelled"] }
        guard currentOrigin(webView) == origin else { return ["status": "origin_changed"] }
        // `frameInfo` records the frame as it was before the sheet opened, so
        // its origin cannot show a navigation since. auth-fill.js compares
        // the origin the sheet named with the frame's document as it runs,
        // in the driver's world, and fills nothing on a mismatch.
        let arguments: [String: Any] = [
            "__fields": fields.map { ["id": $0.id, "type": $0.type, "marker": $0.marker] },
            "__values": values,
            "__origin": fieldsOrigin,
        ]
        do {
            let result = try await webView.browserReplCallAsyncJavaScript(
                fillSource,
                arguments: arguments,
                in: frameInfo,
                contentWorld: BrowserReplDriverWorld.world,
                userGesture: false
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

    /// scheme://host[:port] of the frame that holds the fields (the main
    /// frame when `frameInfo` is nil), from WebKit's security origin.
    static func frameOrigin(_ frameInfo: WKFrameInfo?, _ webView: WKWebView) -> String? {
        guard let frameInfo else { return currentOrigin(webView) }
        return BrowserReplSecretGuard.origin(of: frameInfo)
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

/// The credential sheet: the origin of the frame that receives the values,
/// the page's origin when that frame is embedded from another, a note on who
/// can read the values, one field per requested credential, Cancel and Fill.
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
    /// The wait for the user's answer; it also ends when the call that
    /// asked is cancelled (a cancelled cell, a reset or closed session),
    /// and takes the sheet down then.
    private var prompt: BrowserReplPendingPrompt<Answer>?
    private weak var parent: NSWindow?

    init(origin: String, pageOrigin: String, fields: [BrowserReplCredentialRequest.Field], requester: (tab: String, workspace: String)) {
        self.fields = fields
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        build(origin: origin, pageOrigin: pageOrigin, requester: requester)
    }

    func present(on window: NSWindow, timeout: Duration) async -> Answer {
        let prompt = BrowserReplPendingPrompt<Answer> { [weak self] in self?.takeDown() }
        self.prompt = prompt
        // A call already cancelled shows nothing.
        if !Task.isCancelled {
            parent = window
            // The completion-handler form: in an async function the plain
            // call is the async overload, which would wait for the sheet.
            window.beginSheet(panel, completionHandler: nil)
            NSApp.requestUserAttention(.informationalRequest)
            panel.makeFirstResponder(inputs.first)
        }
        return await prompt.wait(timeout: timeout, expired: .expired, cancelled: .cancelled)
    }

    private func build(origin: String, pageOrigin: String, requester: (tab: String, workspace: String)) {
        let title = NSTextField(labelWithString: String(
            format: String(localized: "browser.repl.auth.title", defaultValue: "Sign in to %@"),
            origin
        ))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        var notes: [NSTextField] = []
        // The sheet comes up on the window the user works in, which may show
        // another workspace than the agent's tab; name the tab that asks.
        let asker = NSTextField(wrappingLabelWithString: String(
            format: String(
                localized: "browser.repl.auth.requester",
                defaultValue: "Asked by an agent working in the tab “%1$@” of the workspace “%2$@”."
            ),
            requester.tab, requester.workspace
        ))
        asker.preferredMaxLayoutWidth = 380
        notes.append(asker)
        if pageOrigin != origin {
            let framed = NSTextField(wrappingLabelWithString: String(
                format: String(
                    localized: "browser.repl.auth.embedded",
                    defaultValue: "This form is in a frame from %1$@, inside a page from %2$@."
                ),
                origin, pageOrigin
            ))
            framed.preferredMaxLayoutWidth = 380
            notes.append(framed)
        }
        let note = NSTextField(wrappingLabelWithString: String(
            localized: "browser.repl.auth.notice",
            defaultValue: "An agent asked cmux to fill this sign-in form. The agent does not receive what you type, but scripts on the page, and code the agent runs in the page, can read the filled fields."
        ))
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380
        notes.append(note)

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

        let stack = NSStackView(views: [title] + notes + [grid, buttons])
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
        prompt?.finish(answer)
    }

    /// Clears what the user typed and takes the sheet down, once the prompt
    /// ended (an answer, the timeout, or the call's cancellation).
    private func takeDown() {
        for input in inputs { input.stringValue = "" }
        parent?.endSheet(panel)
        parent = nil
    }
}
