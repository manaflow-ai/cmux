import Foundation

/// Whether the first-run base keymap chooser should open.
///
/// The chooser asks the question a game asks at first launch, WASD or arrow
/// keys, so it is only worth asking once and only of someone who has no
/// answer yet. Every other case keeps the keymap exactly as it is.
public enum ShortcutKeymapChooserDecision: String, Sendable, Equatable, CaseIterable {
    /// A fresh install that has never been asked: open the chooser.
    case open
    /// An install that was already in use before the chooser shipped. Their
    /// bindings stay as they are and the chooser stays shut; Settings and the
    /// command palette still reach it.
    case skipExistingInstall
    /// This install already answered or dismissed the chooser once.
    case alreadyAnswered
}

/// Decides whether a launch should open the first-run base keymap chooser.
///
/// The policy takes plain booleans rather than reading disk so it can be
/// tested without a file system or a host app. The caller owns both signals.
public struct ShortcutKeymapChooserPolicy: Sendable {
    /// Decides whether this launch opens the chooser.
    ///
    /// Answering wins over install history so that a fresh install which
    /// answers the chooser and then writes its first config file is not asked
    /// again on the next launch.
    ///
    /// - Parameters:
    ///   - hasAnsweredChooser: Whether this install recorded an answer, which
    ///     includes dismissing the chooser without picking a preset.
    ///   - installHasHistory: Whether cmux has been used on this machine
    ///     before, from any signal the host can read cheaply, such as an
    ///     existing settings file or saved workspaces. An install with history
    ///     predates the chooser, so asking it would risk changing keys that
    ///     someone already learned.
    /// - Returns: The decision for this launch.
    public static func decide(
        hasAnsweredChooser: Bool,
        installHasHistory: Bool
    ) -> ShortcutKeymapChooserDecision {
        if hasAnsweredChooser {
            return .alreadyAnswered
        }
        if installHasHistory {
            return .skipExistingInstall
        }
        return .open
    }
}

/// One row of a keymap preset's preview: an action and the keys the preset
/// would give it.
public struct ShortcutKeymapHighlight: Sendable, Equatable {
    /// The action being previewed.
    public let action: ShortcutAction
    /// The binding the preset ends up with, whether the preset writes it or
    /// inherits the cmux default.
    public let shortcut: StoredShortcut
    /// Whether this preset writes the binding rather than inheriting it.
    ///
    /// The chooser marks these so someone can see at a glance which keys a
    /// style actually changes and which it simply agrees with.
    public let isWrittenByPreset: Bool

    /// Whether the preview should render digits `1...9` as a range.
    public var usesNumberedDigitRange: Bool { action.usesNumberedDigitMatching }
}

extension ShortcutKeymapPreset {
    /// The actions every preset preview shows, in preview order.
    ///
    /// These are the keys that distinguish one base keymap from another: the
    /// tab bar navigation that presets disagree about, plus the two everyday
    /// keys that give the rest of the preview context. Showing the same rows
    /// for every preset lets the chooser be read as a column comparison.
    public static let highlightActions: [ShortcutAction] = [
        .nextSurface,
        .prevSurface,
        .selectSurfaceByNumber,
        .selectWorkspaceByNumber,
        .newSurface,
        .closeTab,
    ]

    /// The preview rows for this preset.
    ///
    /// This describes the preset itself, not the current config file: it is
    /// what the keys would be on a clean install, which is the question the
    /// chooser asks. Use ``plan(from:legacyBindings:defaultShortcutResolver:)``
    /// when you need the edits against a specific file.
    ///
    /// - Parameter defaultShortcutResolver: The host's factory defaults, used
    ///   for the actions this preset leaves alone.
    /// - Returns: One row per entry in ``highlightActions``, in that order.
    public func highlights(
        defaultShortcutResolver: ShortcutDefaultResolver = .builtIn
    ) -> [ShortcutKeymapHighlight] {
        Self.highlightActions.map { action in
            let written = overrides[action]?.shortcut
            let effective = written
                ?? action.defaultShortcut(using: defaultShortcutResolver)
                ?? .unbound
            return ShortcutKeymapHighlight(
                action: action,
                shortcut: effective.canonicalized(),
                isWrittenByPreset: written != nil
            )
        }
    }
}
