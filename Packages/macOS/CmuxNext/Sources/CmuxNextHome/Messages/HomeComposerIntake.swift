public import AppKit
public import CmuxNextDesign
public import CmuxNextPages
public import CmuxNextSettings

/// The Messages page as the app's file intake reaches it (the App's `HomeMessagesPage`).
@MainActor
public protocol HomeComposerPage: AnyObject {
    /// The files offered to the page for one call (``HomeMessagesIntake``).
    var intake: HomeMessagesIntake { get }
    /// Asks the page `op` (its answer, or nil when it refused or never answered).
    func ask(_ op: String, _ params: [String: JSONValue], within: Duration) async -> JSONValue?
}

/// The one way the app's callers put files in the Home composer a window shows (Attach Files and
/// `cmux home attach`, a viewer quote, a browser highlight): a conversation tab's or the Chief
/// panel's native transcript takes them through its own intake (as a drop, a paste or a pick), and
/// the Messages page through `home.messages.attach` (pageCommands.ts), which reads each file's bytes
/// from the app (``HomeMessagesIntake``) and adds it as a drop does.
@MainActor
public struct HomeComposerIntake {
    public enum Target {
        case native(HomeNativeTranscriptView)
        case page(any HomeComposerPage)
    }

    /// What an attach did, and the composer's names for the files it added (the native draft's
    /// hashes, or the page's tray ids), for ``remove(_:)``.
    public struct Attached: Sendable {
        public let result: HomeAttachResult
        public let ids: [String]
    }

    public let target: Target
    private weak var window: NSWindow?
    /// How long an attach waits for the page (it reads the files' bytes before it answers).
    static let deadline: Duration = .seconds(60)

    /// The Home composer `window` shows that takes files: the one holding the keyboard, else the
    /// first visible one; nil when none does.
    public init?(window: NSWindow?) {
        guard let window else { return nil }
        self.window = window
        var responder = window.firstResponder as? NSView
        while let view = responder {
            if let found = Self.target(of: view) {
                target = found
                return
            }
            responder = view.superview
        }
        var stack = [window.contentView].compactMap { $0 }
        while let view = stack.popLast() {
            if !view.isHiddenOrHasHiddenAncestor, let found = Self.target(of: view) {
                target = found
                return
            }
            stack.append(contentsOf: view.subviews.reversed())
        }
        return nil
    }

    private static func target(of view: NSView) -> Target? {
        if let native = view as? HomeNativeTranscriptView { return native.canAttach ? .native(native) : nil }
        if let page = view as? any HomeComposerPage { return .page(page) }
        return nil
    }

    /// Attaches the files at `paths`. `track`: the answer names the files added (it waits for the
    /// native composer's intake to settle). The native intake starts in this turn, as before.
    public func attach(paths: [String], via: HomeAttachVia, track: Bool = false) async -> Attached {
        switch target {
        case .native(let view):
            guard track else { return Attached(result: view.attachFiles(paths: paths, via: via), ids: []) }
            await view.attachmentsReady()
            let before = Set(view.draftAttachmentHashes)
            let result = view.attachFiles(paths: paths, via: via)
            guard result == .accepted else { return Attached(result: result, ids: []) }
            await view.attachmentsReady()
            return Attached(result: result, ids: view.draftAttachmentHashes.filter { !before.contains($0) })
        case .page(let page):
            let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            guard !urls.isEmpty, let files = await page.intake.offer(urls) else { return Attached(result: .missingFile, ids: []) }
            let tokens = files.compactMap { $0.value(at: ["token"])?.stringValue }
            let answer = await page.ask("home.messages.attach", ["files": .array(files)], within: Self.deadline)
            page.intake.withdraw(tokens)
            guard let ids = answer?.value(at: ["attached"])?.arrayValue else { return Attached(result: .notConnected, ids: []) }
            return Attached(result: .accepted, ids: ids.compactMap(\.stringValue))
        }
    }

    /// Takes back files an attach added (its ``Attached/ids``).
    public func remove(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        switch target {
        case .native(let view): view.removeDraftAttachments(ids)
        case .page(let page): _ = await page.ask("home.messages.detach", ["ids": .array(ids.map(JSONValue.string))], within: Self.deadline)
        }
    }

    /// Opens the file picker (the composer's attach button): the native composer's own, or for
    /// the page the app's panel made ahead, whose choice goes in as a pick.
    public func pickFiles(openPanel: MadeAheadOpenPanel) {
        switch target {
        case .native(let view): view.pickFiles()
        case .page:
            guard let window else { return }
            HomeAttachmentPanel(openPanel: openPanel).present(for: window) { urls in
                guard let urls, !urls.isEmpty else { return }
                // task-owner: one page call for the person's pick; ends with its answer (bounded by `deadline`)
                Task { _ = await attach(paths: urls.map(\.path), via: .pick) }
            }
        }
    }
}
