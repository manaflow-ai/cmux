import Foundation

/// A snapshot of the focus dimensions a ``ShortcutWhenClause`` evaluates against.
///
/// `terminalFocus` is derived: a terminal owns focus exactly when no browser,
/// markdown, file-preview text editor, or sidebar focus is present.
///
/// This is the focus-only projection of the broader ``ShortcutContext``; its
/// ``context`` property lifts the four focus atoms into a context so the same
/// clause engine can evaluate both focus-only and richer predicates.
public struct ShortcutFocusState: Equatable, Sendable {
    /// Whether a browser panel owns focus for the shortcut event.
    public var browser: Bool
    /// Whether a markdown preview owns focus for the shortcut event.
    public var markdown: Bool
    /// Whether a file-preview text editor owns focus for the shortcut event.
    public var filePreviewTextEditor: Bool
    /// Whether the right sidebar owns focus for the shortcut event.
    public var sidebar: Bool

    /// Creates a focus snapshot from the app target's current shortcut focus dimensions.
    ///
    /// - Parameters:
    ///   - browser: Whether a browser panel owns focus for the shortcut event.
    ///   - markdown: Whether a markdown preview owns focus for the shortcut event.
    ///   - sidebar: Whether the right sidebar owns focus for the shortcut event.
    ///   - filePreviewTextEditor: Whether a file-preview text editor owns focus for the shortcut event.
    public init(browser: Bool, markdown: Bool, sidebar: Bool, filePreviewTextEditor: Bool = false) {
        self.browser = browser
        self.markdown = markdown
        self.sidebar = sidebar
        self.filePreviewTextEditor = filePreviewTextEditor
    }

    /// Whether a terminal owns focus, derived from the absence of every other tracked focus atom.
    public var terminal: Bool { !browser && !markdown && !filePreviewTextEditor && !sidebar }

    /// Returns the boolean value of a supported focus atom in this snapshot.
    ///
    /// - Parameter atom: The focus atom to read.
    /// - Returns: The atom's value in this focus state.
    public func value(of atom: ShortcutFocusAtom) -> Bool {
        switch atom {
        case .sidebarFocus: return sidebar
        case .browserFocus: return browser
        case .markdownFocus: return markdown
        case .filePreviewTextEditorFocus: return filePreviewTextEditor
        case .terminalFocus: return terminal
        }
    }

    /// The focus atoms lifted into a ``ShortcutContext``.
    ///
    /// Writes the focus keys (`sidebarFocus`, `browserFocus`, `markdownFocus`,
    /// `filePreviewTextEditorFocus`, `terminalFocus`) as boolean values. The app target starts from this and adds
    /// the non-focus keys (e.g. `commandPaletteVisible`, `paneCount`) before
    /// evaluating a clause.
    public var context: ShortcutContext {
        var context = ShortcutContext()
        context.setBool(ShortcutFocusAtom.sidebarFocus.rawValue, sidebar)
        context.setBool(ShortcutFocusAtom.browserFocus.rawValue, browser)
        context.setBool(ShortcutFocusAtom.markdownFocus.rawValue, markdown)
        context.setBool(ShortcutFocusAtom.filePreviewTextEditorFocus.rawValue, filePreviewTextEditor)
        context.setBool(ShortcutFocusAtom.terminalFocus.rawValue, terminal)
        return context
    }

    /// The set of focus states the runtime can actually produce.
    ///
    /// `markdownFocus` and `filePreviewTextEditorFocus` never co-occur with
    /// `browserFocus` (the focus computation only treats those panels as focused
    /// when no browser panel owns the event), so those combinations are excluded. Everything
    /// else is treated as realizable, which keeps conflict detection
    /// conservative (it would rather flag a possible collision than miss one).
    public static let realizableStates: [ShortcutFocusState] = {
        var states: [ShortcutFocusState] = []
        for browser in [false, true] {
            for markdown in [false, true] {
                for filePreviewTextEditor in [false, true] {
                    for sidebar in [false, true] {
                        if browser && markdown { continue }
                        if browser && filePreviewTextEditor { continue }
                        if markdown && filePreviewTextEditor { continue }
                        states.append(ShortcutFocusState(
                            browser: browser,
                            markdown: markdown,
                            sidebar: sidebar,
                            filePreviewTextEditor: filePreviewTextEditor
                        ))
                    }
                }
            }
        }
        return states
    }()
}
