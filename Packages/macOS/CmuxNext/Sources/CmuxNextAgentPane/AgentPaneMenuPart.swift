import AppKit
import CmuxNextActions

/// The part of a message under the pointer, as the page reports it: a code block, a command and
/// its output, a file path or a web link. Each comes from reply text, so a path opens only through
/// the page's `link.openPath` (the host checks it again) and a link only if it is a web link.
struct AgentPaneMenuPart: Equatable, Sendable {
    var code: String?
    var command: String?
    var output: String?
    var path: String?
    var line: FileLineLocation?
    var link: URL?

    init(code: String? = nil, command: String? = nil, output: String? = nil, path: String? = nil, link: URL? = nil) {
        self.code = code
        self.command = command
        self.output = output
        self.path = path
        self.link = link
    }

    /// Nil when the report names none of them.
    init?(report body: Any?) {
        guard let object = body as? [String: Any] else { return nil }
        func text(_ key: String) -> String? { (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        code = text("code")
        command = text("command")
        output = text("output")
        path = text("path")
        line = text("line").flatMap(FileLineLocation.init)
        link = text("link").flatMap(URL.init(string:)).flatMap { AgentPaneMessageTarget.isWebLink($0) ? $0 : nil }
        guard code != nil || command != nil || output != nil || path != nil || link != nil else { return nil }
    }

    /// Copy Code; Copy Command and Copy Output; Open and the path rows (`pathItems`, else Copy
    /// Path); the link rows (`linkItems`, else Open Link and Copy Link).
    @MainActor
    func items(copy: @escaping (String) -> Void, openPath: @escaping (String, FileLineLocation?) -> Void,
               open: @escaping (URL) -> Void, linkItems: ((URL) -> [NSMenuItem])? = nil,
               pathItems: ((String) -> [NSMenuItem]?)? = nil) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let code { items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyCode, symbol: "chevron.left.forwardslash.chevron.right") { copy(code) }) }
        if let command { items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyCommand, symbol: "terminal") { copy(command) }) }
        if let output { items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyOutput, symbol: "doc.plaintext") { copy(output) }) }
        if let path {
            items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.open, symbol: "doc") { openPath(path, line) })
            items += pathItems?(path) ?? [AgentPaneMenuAction.item(AgentPaneMenuStrings.copyPath, symbol: "doc.on.doc") { copy(path) }]
        }
        if let link, let linkItems {
            items += linkItems(link)
        } else if let link {
            items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.openLink, symbol: "arrow.up.right.square") { open(link) })
            items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyLink, symbol: "link") { copy(link.absoluteString) })
        }
        return items
    }
}
