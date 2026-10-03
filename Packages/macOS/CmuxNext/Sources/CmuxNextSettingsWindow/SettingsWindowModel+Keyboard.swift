public import AppKit
public import CmuxNextActions

/// Keyboard section: every bindable action with its shortcut, and the
/// shared recorder (`ShortcutRecorder`, the palette's Cmd-K editor) with the
/// same refusals, conflicts, Keep Both, Replace and Restore Default.
extension SettingsWindowModel {
    /// Every action grouped by category, filtered by `query` (title, id,
    /// keywords or keys: "cmd shift p", "⌘D").
    public func shortcutSections() -> [ShortcutSection] {
        let words = Self.words(query)
        let conflicted = Set(registry.shortcutConflicts().flatMap { $0 })
        let refusedSystemWide = host?.systemWideRefusals ?? []
        var byCategory: [ActionCategory: [ShortcutRow]] = [:]
        for entry in registry.entries {
            let descriptor = entry.descriptor
            // Every action is bindable (REWRITE.md action contract), so every
            // action is listed, with or without a shortcut.
            let keycaps = registry.shortcutKeycaps(for: descriptor.id)
            if !words.isEmpty {
                var haystack = [descriptor.title, descriptor.id.rawValue, descriptor.category.title] + descriptor.keywords
                if let keycaps { haystack.append(keycaps.joined()) }
                if let shortcut = registry.effectiveShortcut(for: descriptor.id) { haystack += shortcut.searchTokens }
                let text = haystack.joined(separator: " ")
                guard words.allSatisfy({ text.localizedStandardContains($0) }) else { continue }
            }
            byCategory[descriptor.category, default: []].append(ShortcutRow(
                id: descriptor.id, title: descriptor.title, keycaps: keycaps,
                isCustomized: registry.shortcutOverrides[descriptor.id] != nil || registry.chordOverrides[descriptor.id] != nil,
                hasConflict: conflicted.contains(descriptor.id),
                isRefusedSystemWide: refusedSystemWide.contains(descriptor.id)))
        }
        return ActionCategory.allCases.compactMap { category in
            byCategory[category].map { ShortcutSection(category: category, rows: $0) }
        }
    }

    /// Starts recording a shortcut for `id` (a click on its row).
    @discardableResult
    public func beginRecording(_ id: ActionID) -> Bool {
        shortcutRecorder.editor = host?.shortcutEditor
        notice = nil
        return shortcutRecorder.begin(id)
    }

    /// A key-down while recording; the window routes every key here then.
    @discardableResult
    public func handleRecorderKey(_ event: NSEvent) -> Bool {
        guard recorder != nil else { return false }
        return shortcutRecorder.handle(ShortcutRecorder.shortcut(for: event), keyCode: event.keyCode, event: event)
    }

    /// A key-down as the recorder sees it (tests and `debug.key`).
    @discardableResult
    public func handleRecorderKey(_ shortcut: Shortcut, keyCode: UInt16 = 0) -> Bool {
        guard recorder != nil else { return false }
        return shortcutRecorder.handle(shortcut, keyCode: keyCode)
    }

    public func chooseRecorderOption(_ option: ShortcutRecorderOption) {
        shortcutRecorder.choose(option)
    }

    public func cancelRecording() { shortcutRecorder.cancel() }
}

public struct ShortcutSection: Identifiable, Sendable {
    public let category: ActionCategory
    public let rows: [ShortcutRow]
    public var id: String { category.rawValue }
}

public struct ShortcutRow: Identifiable, Hashable, Sendable {
    public let id: ActionID
    public let title: String
    public let keycaps: [String]?
    public let isCustomized: Bool
    /// Another action claims the same shortcut in the same context.
    public let hasConflict: Bool
    /// A global action whose key another app (or another global action)
    /// holds: it runs only while cmux is in front.
    public let isRefusedSystemWide: Bool
}
