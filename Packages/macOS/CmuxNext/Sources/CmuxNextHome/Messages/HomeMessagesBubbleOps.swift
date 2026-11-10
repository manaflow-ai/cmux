public import AppKit
public import CmuxHomeCore
import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings
import Foundation
import Quartz

/// The Messages page's bubble menu rows that only the app runs (the native transcript's menu,
/// MessagesLabHome `PaneMenu.swift`; the page builds the rows, webviews `transcript/bubbleMenu.ts`).
/// The App's `HomeMessagesHostProvider` routes `cmux.home.messages.bubble.*` here:
/// - `bubble.facts {conversation}` -> `{linkScheme, forward, share, retryReply, files}`: what a
///   bubble's menu offers there (Retry Reply only for a Chief this app's brain answers, never a
///   Cloud-hosted one, as `HomeChiefTurnActions`: ``Host/retryReply`` gives no run for it);
/// - `bubble.retryReply {conversation, message}`: `chief.retry` on my committed message;
/// - `bubble.forward {text}`: Send To… with the text (the palette asks which chat or agent);
/// - `bubble.share {text | url}`: the system share picker at the pointer;
/// - `bubble.file {action, path | attachment {conversation, message, partIndex, part}}`: a path
///   link's or an attachment's row (Open in Right Pane, Open With, Quick Look, Show in Finder, Copy
///   as Pathname; an attachment's Copy and Save As…), through the host's file actions.
/// Every op but `facts` runs only on the person's click (`refusal` otherwise).
@MainActor
public final class HomeMessagesBubbleOps {
    /// What the app gives these rows.
    public struct Host {
        /// The build's link scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`): Copy Link's permalinks.
        public var linkScheme: String
        /// `chief.retry` on a message of a conversation's Chief (true when the brain took it); nil
        /// when the Chief has no brain this app reaches (a Cloud-hosted one).
        public var retryReply: @MainActor (ConversationID) -> (@MainActor (String) async -> Bool)?
        /// Send To… with a text (the palette asks which chat or agent); true when it ran.
        public var forward: @MainActor (String) -> Bool
        /// Opens a file where cmux shows files (the right of Home), never in Finder.
        public var openFile: @MainActor (URL) -> Void
        /// The host's file menu for a file named `name` (FileActionsMenu): its Open With submenu.
        public var fileMenu: @MainActor (_ name: String, _ resolve: @escaping @MainActor @Sendable () async -> URL?) -> [NSMenuItem]

        public init(linkScheme: String, retryReply: @escaping @MainActor (ConversationID) -> (@MainActor (String) async -> Bool)?,
                    forward: @escaping @MainActor (String) -> Bool, openFile: @escaping @MainActor (URL) -> Void,
                    fileMenu: @escaping @MainActor (String, @escaping @MainActor @Sendable () async -> URL?) -> [NSMenuItem]) {
            self.linkScheme = linkScheme
            self.retryReply = retryReply
            self.forward = forward
            self.openFile = openFile
            self.fileMenu = fileMenu
        }
    }

    /// The ops' prefix after `cmux.home.messages.`.
    public static let prefix = "bubble."
    /// The file actions a row may ask for.
    enum FileAction: String { case open, openWith, quickLook, reveal, copyPath, copy, saveAs }

    private let store: HomeStore
    private let host: Host
    private let quickLook = BubbleQuickLook()

    public init(store: HomeStore, host: Host) {
        self.store = store
        self.host = host
    }

    /// Answers `name` (the op after `cmux.home.messages.`), or nil when it is not one of these.
    /// `refusal`: what a run without the person's click throws (nil: it is one).
    public func call(_ name: String, _ fields: [String: JSONValue], refusal: PageError?) async throws -> JSONValue? {
        guard name.hasPrefix(Self.prefix) else { return nil }
        let op = String(name.dropFirst(Self.prefix.count))
        if op == "facts" { return facts(try Self.conversation(fields)) }
        if let refusal { throw refusal }
        switch op {
        case "retryReply":
            let id = try Self.conversation(fields)
            guard let message = fields["message"]?.stringValue, !message.isEmpty, message.count <= 256 else {
                throw PageError.invalidParams("message must be a message id")
            }
            guard let retry = host.retryReply(id) else { return .object(["ran": .bool(false)]) }
            return .object(["ran": .bool(await retry(message))])
        case "forward":
            guard let text = fields["text"]?.stringValue, !text.isEmpty else { throw PageError.invalidParams("text must not be empty") }
            return .object(["ran": .bool(host.forward(text))])
        case "share":
            guard let item = Self.shareItem(fields) else { throw PageError.invalidParams("share takes text or an http(s) url") }
            return .object(["ran": .bool(Self.share(item))])
        case "file":
            guard let action = fields["action"]?.stringValue.flatMap(FileAction.init(rawValue:)) else {
                throw PageError.invalidParams("action must name a file row")
            }
            let (name, resolve) = try file(fields)
            return .object(["ran": .bool(await run(action, name: name, resolve: resolve))])
        default:
            throw PageError.unknownOp(name)
        }
    }

    // MARK: Facts

    func facts(_ id: ConversationID) -> JSONValue {
        .object([
            "linkScheme": .string(host.linkScheme),
            "forward": .bool(true),
            "share": .bool(true),
            "retryReply": .bool(host.retryReply(id) != nil),
            "files": .bool(true),
        ])
    }

    // MARK: Share

    /// Share…'s item (PaneMenu `shareItems`): an http(s) link, else the text.
    static func shareItem(_ fields: [String: JSONValue]) -> Any? {
        if let text = fields["url"]?.stringValue, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        if let text = fields["text"]?.stringValue, !text.isEmpty { return text }
        return nil
    }

    /// The system share picker at the pointer, in the key window.
    private static func share(_ item: Any) -> Bool {
        guard let view = NSApp.keyWindow?.contentView, let window = view.window else { return false }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [item]).show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
        return true
    }

    // MARK: Files

    /// The file a row acts on: its name, and its copy on disk when the row runs (an attachment is
    /// fetched only then, as the native rows did).
    func file(_ fields: [String: JSONValue]) throws -> (String, @MainActor @Sendable () async -> URL?) {
        if let path = fields["path"]?.stringValue {
            guard path.hasPrefix("/"), path.count <= 4096 else { throw PageError.invalidParams("path must be absolute") }
            let url = URL(fileURLWithPath: path)
            return (url.lastPathComponent, { url })
        }
        guard let attachment = fields["attachment"]?.objectValue,
              let conversation = attachment["conversation"]?.stringValue, !conversation.isEmpty, conversation.count <= 256,
              let message = attachment["message"]?.stringValue, !message.isEmpty, message.count <= 256,
              let part = attachment["part"]?.objectValue,
              let hash = part["hash"]?.stringValue, !hash.isEmpty, hash.count <= 256,
              let name = part["name"]?.stringValue, !name.isEmpty else {
            throw PageError.invalidParams("file rows take a path or an attachment")
        }
        let ref = AttachmentRef(hash: hash, name: name, mimeType: part["mimeType"]?.stringValue ?? "application/octet-stream",
                                byteCount: part["byteCount"]?.intValue ?? 0)
        let location = AttachmentLocation(conversation: ConversationID(conversation), message: MessageID(message),
                                          partIndex: attachment["partIndex"]?.intValue)
        let store = store
        return (name, { @MainActor in
            guard let blob = try? await store.fetchAttachment(ref, at: location, variant: .original) else { return nil }
            // The store names its copy by hash; the viewer, Open With and Save As read the attachment's name.
            return await Task.detached(priority: .userInitiated) { (try? Self.namedCopy(of: blob, name: name, hash: hash)) ?? blob }.value
        })
    }

    /// A copy of `blob` named `name`, in a folder of its own per hash (made once).
    nonisolated static func namedCopy(of blob: URL, name: String, hash: String) throws -> URL {
        let safe = (name as NSString).lastPathComponent
        guard !safe.isEmpty, safe != ".", safe != ".." else { return blob }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-home-attachments", isDirectory: true)
            .appendingPathComponent(String(hash.prefix(64)), isDirectory: true)
        let named = folder.appendingPathComponent(safe)
        if FileManager.checked.fileExists(atPath: named.path) { return named }
        try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try FileManager.checked.linkItem(at: blob, to: named) } catch { try FileManager.checked.copyItem(at: blob, to: named) }
        return named
    }

    private func run(_ action: FileAction, name: String, resolve: @escaping @MainActor @Sendable () async -> URL?) async -> Bool {
        if action == .openWith {
            // The host's Open With submenu (every app for the type, the default first), at the pointer.
            guard let submenu = host.fileMenu(name, resolve).first(where: { $0.submenu != nil })?.submenu,
                  let view = NSApp.keyWindow?.contentView, let window = view.window else { return false }
            return submenu.popUp(positioning: nil, at: view.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: view)
        }
        // The page's call waits for the file (an attachment may download), then the row runs.
        guard let file = await resolve() else { return false }
        switch action {
        case .open: host.openFile(file)
        case .openWith: break
        case .quickLook: quickLook.show(file)
        case .reveal: NSWorkspace.shared.revealInBackground([file])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([file as NSURL])
        case .saveAs: Self.saveAs(file, name: name)
        }
        return true
    }

    /// Save As…: the save panel named like the attachment, then a copy of its bytes there (an older
    /// file there is replaced: the panel already asked), off the main thread.
    private static func saveAs(_ file: URL, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (name as NSString).lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            // task-owner: one copy; ends when the bytes are in place
            Task.detached(priority: .userInitiated) { try? Self.save(file, to: destination) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    /// Copies `file` to `destination` through a staged file, replacing one already there.
    nonisolated static func save(_ file: URL, to destination: URL) throws {
        if file.standardizedFileURL == destination.standardizedFileURL { return }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        try FileManager.checked.copyItem(at: file, to: staged)
        do {
            if FileManager.checked.fileExists(atPath: destination.path) {
                _ = try FileManager.checked.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.checked.moveItem(at: staged, to: destination)
            }
        } catch {
            try? FileManager.checked.removeItem(at: staged)
            throw error
        }
    }

    // MARK: Wire

    static func conversation(_ fields: [String: JSONValue]) throws -> ConversationID {
        guard let id = fields["conversation"]?.stringValue, !id.isEmpty, id.count <= 256 else {
            throw PageError.invalidParams("conversation must be a conversation id")
        }
        return ConversationID(id)
    }
}

/// Quick Look of one file (the shared preview panel).
@MainActor
final class BubbleQuickLook: NSObject, QLPreviewPanelDataSource {
    private var file: URL?

    func show(_ file: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.file = file
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // An isolated conformance (InferIsolatedConformances), as CmuxNextFilesUI's QuickLookSource:
    // QLPreviewPanel asks its data source on the main thread.
    func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int {
        file == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? {
        index == 0 ? file.map { $0 as NSURL } : nil
    }
}
