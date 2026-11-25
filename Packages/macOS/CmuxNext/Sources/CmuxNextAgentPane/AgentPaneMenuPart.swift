import AppKit

/// The part of a message under the pointer, as the page reports it: a code block, a command and
/// its output, a file path, a web link, or a chat a click opens (`session`). Each comes from reply
/// text, so a path opens only through the page's `link.openPath` (the host checks it again), a link
/// only if it is a web link, and a chat only as the click's `chat.offer.open` may
/// (``AgentPaneOfferOpen``).
struct AgentPaneMenuPart: Equatable, Sendable {
    var code: String?
    var command: String?
    var output: String?
    var path: String?
    var link: URL?
    /// The chat a click on the element opens (a started chat's card, a sender's name...).
    var session: String?
    /// ``session`` is a message's sender (`chat.offer.open`'s `sender`).
    var sender = false

    init(code: String? = nil, command: String? = nil, output: String? = nil, path: String? = nil, link: URL? = nil,
         session: String? = nil, sender: Bool = false) {
        self.code = code
        self.command = command
        self.output = output
        self.path = path
        self.link = link
        self.session = session
        self.sender = sender
    }

    /// Nil when the report names none of them.
    init?(report body: Any?) {
        guard let object = body as? [String: Any] else { return nil }
        func text(_ key: String) -> String? { (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        code = text("code")
        command = text("command")
        output = text("output")
        path = text("path")
        link = text("link").flatMap(URL.init(string:)).flatMap { AgentPaneMessageTarget.isWebLink($0) ? $0 : nil }
        // An acpmux session id, bounded as `chat.offer.open` bounds it.
        session = text("session").flatMap { $0.count <= 256 ? $0 : nil }
        sender = session != nil && (object["sender"] as? NSNumber)?.boolValue == true
        guard code != nil || command != nil || output != nil || path != nil || link != nil || session != nil else { return nil }
    }

    /// Open on Right and Go to Chat (when `goToSession` answers one); Copy Code; Copy Command and
    /// Copy Output; Open and the path rows (`pathItems`, else Copy Path); the link rows
    /// (`linkItems`, else Open Link and Copy Link).
    @MainActor
    func items(copy: @escaping (String) -> Void, openPath: @escaping (String) -> Void,
               open: @escaping (URL) -> Void, linkItems: ((URL) -> [NSMenuItem])? = nil,
               pathItems: ((String) -> [NSMenuItem]?)? = nil,
               openSession: ((String, Bool) -> Void)? = nil,
               goToSession: ((String, Bool) -> (@MainActor () -> Void)?)? = nil) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let session, let openSession {
            items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.openOnRight, symbol: "rectangle.righthalf.inset.filled") { openSession(session, sender) })
            if let goTo = goToSession?(session, sender) {
                items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.goToChat, symbol: "arrow.right.square") { goTo() })
            }
        }
        if let code { items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyCode, symbol: "chevron.left.forwardslash.chevron.right") { copy(code) }) }
        if let command { items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyCommand, symbol: "terminal") { copy(command) }) }
        if let output { items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyOutput, symbol: "doc.plaintext") { copy(output) }) }
        if let path {
            items.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.open, symbol: "doc") { openPath(path) })
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
