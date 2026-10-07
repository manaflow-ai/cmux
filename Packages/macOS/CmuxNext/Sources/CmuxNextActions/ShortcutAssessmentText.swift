import Foundation

/// The words for a `ShortcutAssessment`, shared by every place that edits a
/// shortcut (the palette recorder, the Settings Keyboard Shortcuts page), so
/// a refusal or a conflict reads the same everywhere.
@MainActor
public struct ShortcutAssessmentText {
    public let registry: ActionRegistry

    public init(_ registry: ActionRegistry) {
        self.registry = registry
    }

    public func title(_ id: ActionID) -> String {
        registry.descriptor(for: id)?.title ?? id.rawValue
    }

    public func titles(_ ids: [ActionID]) -> String {
        ListFormatter.localizedString(byJoining: ids.map(title))
    }

    public func refusal(_ refusal: ShortcutRefusal, shortcut: Shortcut, id: ActionID) -> String {
        switch refusal {
        case .needsModifier: ShortcutRecorderStrings.shortcutNeedsModifier
        case .reservedByMacOS(let name): ShortcutRecorderStrings.shortcutReservedByMacOS(shortcut.displayString, name)
        case .systemAction(let owner): ShortcutRecorderStrings.shortcutOwnedBySystemAction(shortcut.displayString, title(owner))
        case .numberedFamily(let owner): ShortcutRecorderStrings.shortcutInNumberedFamily(shortcut.displayString, title(owner))
        case .editsNumberedFamily: ShortcutRecorderStrings.shortcutFamilyInConfig(id.rawValue)
        }
    }

    public func conflict(_ shortcut: Shortcut, owners: [ActionID], canKeepBoth: Bool) -> String {
        let used = ShortcutRecorderStrings.shortcutUsedBy(shortcut.displayString, titles(owners))
        return canKeepBoth ? used + " " + ShortcutRecorderStrings.shortcutCanKeepBoth : used
    }
}
