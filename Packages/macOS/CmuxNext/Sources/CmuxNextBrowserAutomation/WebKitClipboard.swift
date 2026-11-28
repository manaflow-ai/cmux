import Foundation
import WebKit

/// The per-tab virtual clipboard (driver protocol `clipboard.read` /
/// `clipboard.write`), as the CDP driver keeps it (cdp/clipboard.rs): Meta+C,
/// Meta+X and Meta+V in a driven tab never touch the system pasteboard. The
/// key still reaches the page (trusted); then the driver runs the command in
/// the main frame's host world: a `copy`, `cut` or `paste` event with a
/// `DataTransfer`, and its default action (the selection's text to the tab's
/// clipboard, a cut's deletion, a paste's text through the text input
/// client, which is trusted input). A key the page's `keydown` prevented
/// runs no command.
@MainActor
struct WebKitClipboard {
    let driver: WebKitDriver

    /// The most bytes (base64) one tab's clipboard holds.
    private static let maxClipboardBytes = 32 << 20

    /// Records the next `keydown`; its `defaultPrevented` is read after it.
    private static let recordKey = """
    globalThis.__cmuxClipboardKey = null;
    addEventListener("keydown", (e) => { globalThis.__cmuxClipboardKey = e; }, { capture: true, once: true });
    return true;
    """

    /// `kind` ("copy" | "cut" | "paste") unless the recorded keydown was
    /// prevented: Copy and Cut return `{ entries: [[type, text]] }`, Paste
    /// `{ insert: text | null }`; `null` when the page prevented the key.
    private static let runCommand = """
    const key = globalThis.__cmuxClipboardKey; globalThis.__cmuxClipboardKey = null;
    if (key && key.defaultPrevented) return null;
    const doc = document; const active = doc.activeElement;
    const field = active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA") && typeof active.selectionStart === "number";
    const selection = getSelection();
    const anchor = selection && selection.anchorNode;
    const target = field ? active : anchor ? (anchor.nodeType === 1 ? anchor : anchor.parentElement) : (active || doc.body || doc.documentElement);
    const data = new DataTransfer();
    if (kind === "paste") {
      for (const item of items) {
        const bin = atob(item.base64); const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        if (/^text\\//.test(item.type)) data.setData(item.type, new TextDecoder().decode(bytes));
        else data.items.add(new File([bytes], "clipboard", { type: item.type }));
      }
    }
    const event = new ClipboardEvent(kind, { bubbles: true, cancelable: true, composed: true, clipboardData: data });
    const cancelled = !(target || doc).dispatchEvent(event);
    if (kind === "paste") return { insert: cancelled ? null : data.getData("text/plain") || null };
    if (cancelled) return { entries: Array.from(data.types).filter((t) => t !== "Files").map((t) => [t, data.getData(t)]) };
    const text = field ? String(active.value).slice(active.selectionStart, active.selectionEnd) : String(selection || "");
    if (kind === "cut" && text) doc.execCommand("delete", false, "");
    return { entries: text ? [["text/plain", text]] : [] };
    """

    /// The command of a Copy, Cut or Paste shortcut (Meta+C/X/V key down).
    static func clipboardShortcut(_ params: DriverParams) -> String? {
        guard (try? params.string("type")) == "down", (try? params.strings("modifiers"))?.contains("Meta") == true else { return nil }
        let code = (try? params.optionalString("code")) ?? nil
        let key = ((try? params.string("key")) ?? "").lowercased()
        switch (code ?? "", key) {
        case ("KeyC", _), ("", "c"): return "copy"
        case ("KeyX", _), ("", "x"): return "cut"
        case ("KeyV", _), ("", "v"): return "paste"
        default: return nil
        }
    }

    func clipboardRead(_ params: DriverParams) throws(DriverError) -> DriverJSON {
        let (_, session) = try driver.target(params)
        return .object(["items": .array(session.clipboard)])
    }

    func clipboardWrite(_ params: DriverParams) throws(DriverError) -> DriverJSON {
        let (_, session) = try driver.target(params)
        var size = 0
        var items: [DriverJSON] = []
        for item in try params.array("items") {
            guard case .object(let fields) = item, case .string(let type)? = fields["type"], case .string(let data)? = fields["base64"] else {
                throw DriverError(.invalid, "clipboard.write: every item needs a type and base64")
            }
            size += data.utf8.count
            guard size <= Self.maxClipboardBytes else { throw DriverError(.invalid, "clipboard.write: the items are larger than 32 MiB") }
            items.append(.object(["type": .string(type), "base64": .string(data)]))
        }
        session.clipboard = items
        return .null
    }

    /// `input.key` down of a Copy, Cut or Paste shortcut: the key goes to the
    /// page, then the command runs against the tab's clipboard.
    func clipboardKey(_ kind: String, _ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try driver.target(params)
        _ = try await driver.run(Self.recordKey, [:], nil, AgentWorld.hostWorld, tab)
        _ = try await driver.inputKey(params, nativeCommand: false)
        let pasted: [Any] = kind == "paste" ? session.clipboard.map(\.foundationValue) : []
        let result = try await CallDeadline.run(.seconds(5), what: kind) { () throws(DriverError) in
            try await driver.run(Self.runCommand, ["kind": kind, "items": pasted], nil, AgentWorld.hostWorld, tab)
        }
        guard case .object(let fields) = result else { return .null }
        if kind == "paste" {
            if case .string(let text)? = fields["insert"] { _ = try await driver.inputInsertText(DriverParams(method: "input.insertText", json: .object([
                "targetId": .string(tab.id.rawValue), "text": .string(text),
            ]))) }
            return .null
        }
        guard case .array(let entries)? = fields["entries"] else { return .null }
        let items: [DriverJSON] = entries.compactMap { entry in
            guard case .array(let pair) = entry, pair.count == 2, case .string(let type) = pair[0], case .string(let text) = pair[1] else { return nil }
            return .object(["type": .string(type), "base64": .string(Data(text.utf8).base64EncodedString())])
        }
        // A command that put nothing there leaves the clipboard as it was.
        if !items.isEmpty { session.clipboard = items }
        return .null
    }
}
