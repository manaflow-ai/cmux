public import AppKit
public import CmuxNextActions
public import CmuxNextDesign
import CmuxNextWindowRules
import UniformTypeIdentifiers

/// Insert Photo… (`insertPhoto`): an image-only open panel, then the chosen pictures go into the
/// focused pane. An agent chat takes them into its composer as an unsent draft, as a drop does
/// (``AgentPaneView/attachExternal(_:claimed:)``); a terminal gets their shell-quoted paths pasted
/// into its input, the form Claude Code and Codex read an image from. A `path` argument (action.run,
/// MCP) inserts that file without the panel. Any other pane refuses with the reason.
@MainActor
public struct InsertPhotoAction {
    public static let id: ActionID = "insertPhoto"

    /// The focused pane, as Insert Photo sees it.
    public enum Target {
        /// An agent chat: `attach` puts the files into its composer.
        case chat(attach: @MainActor ([URL]) -> Void)
        /// A terminal: `send` pastes the text into its input and answers the failure, if any.
        /// `isLocal`: the panel's files are on this Mac, so only a local terminal can read them.
        case terminal(isLocal: Bool, send: @MainActor (String) async -> ActionWorkFailure?)
        /// A pane that takes no picture (a browser, a page): the refusal says why.
        case refused(String)
    }

    private let target: @MainActor (ActionInvocation) -> Target?
    private let choose: @MainActor () async -> [URL]
    private let shellQuoted: @Sendable (String) -> String?

    /// - Parameters:
    ///   - target: The invocation's pane; nil when there is none (nothing runs).
    ///   - choose: The pictures the person picks; empty on Cancel (``choosePhotos(_:window:)``).
    ///   - shellQuoted: One path as one shell word; Rust's `tabs::panes::shell_quoted` (a dropped file's quoting) by default.
    public init(target: @escaping @MainActor (ActionInvocation) -> Target?, choose: @escaping @MainActor () async -> [URL],
                shellQuoted: (@Sendable (String) -> String?)? = nil) {
        self.target = target
        self.choose = choose
        self.shellQuoted = shellQuoted ?? { WindowRules().shellQuoted($0) }
    }

    public func bind(into registry: ActionRegistry) {
        registry.bindEffect(Self.id, effect: { effect(for: $0) })
    }

    /// What one run does: the panel (or the `path` argument), then the pane's own way in.
    public func effect(for invocation: ActionInvocation) -> ActionEffect {
        guard let target = target(invocation) else { return .done }
        let given = invocation["path"]?.stringValue.flatMap { $0.isEmpty ? nil : [URL(fileURLWithPath: $0)] }
        let (choose, shellQuoted) = (choose, shellQuoted)
        switch target {
        case .refused(let reason):
            return .refused(reason)
        case .chat(let attach):
            if let given { attach(given); return .done }
            // action-wait-allow: the person picks in the system's open panel (its own process)
            return .waiting(.externalProcess) {
                let urls = await choose()
                if !urls.isEmpty { attach(urls) }
                return nil
            }
        case .terminal(let isLocal, let send):
            guard given != nil || isLocal else { return .refused(Self.localOnly) }
            // action-wait-allow: the person picks in the system's open panel (its own process); the shell echoes the paths
            return .waiting(.externalProcess) {
                let urls = if let given { given } else { await choose() }
                guard let text = Self.insertText(for: urls, shellQuoted: shellQuoted) else { return nil }
                return await send(text)
            }
        }
    }

    /// The text a terminal gets for `urls`: each path quoted as a dropped file is, joined by a space,
    /// no trailing space. Nil for none, or when a path can't be quoted.
    public nonisolated static func insertText(for urls: [URL], shellQuoted: (String) -> String?) -> String? {
        let words = urls.map { shellQuoted($0.path) }
        guard !words.isEmpty, !words.contains(nil) else { return nil }
        return words.compactMap(\.self).joined(separator: " ")
    }

    /// The pictures the person picks in `openPanel`'s made-ahead panel: image files only, several
    /// at a time, a sheet on `window` (its own window when that one already shows a sheet). Empty
    /// on Cancel, or when no panel could be made.
    public static func choosePhotos(_ openPanel: MadeAheadOpenPanel, window: NSWindow?) async -> [URL] {
        guard let panel = openPanel.panel() else { return [] }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "agentPane.insertPhoto.prompt", defaultValue: "Insert", bundle: .localizedModule)
        // The URLs are read in the panel's own handler: once it ends, the shared panel is free for
        // the next picker, which would reconfigure it before an `await` resumed here.
        return await withCheckedContinuation { done in
            let finish: (NSApplication.ModalResponse) -> Void = { done.resume(returning: $0 == .OK ? panel.urls : []) }
            if let window, window.attachedSheet == nil { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
        }
    }

    /// The refusal of a pane that takes no picture (a browser, a page).
    public static var noPictureTarget: String {
        String(localized: "agentPane.insertPhoto.noTarget", defaultValue: "Insert Photo puts a picture into an agent chat or a terminal; focus one first.",
               bundle: .localizedModule)
    }

    static var localOnly: String {
        String(localized: "agentPane.insertPhoto.localOnly", defaultValue: "Insert Photo picks files on this Mac; a remote terminal can't read them. Pass a path on that machine with --arg path=<file>.",
               bundle: .localizedModule)
    }
}
