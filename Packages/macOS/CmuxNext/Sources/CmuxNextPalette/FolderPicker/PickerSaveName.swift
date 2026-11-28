public import Foundation

/// The save picker's name field: pure rules for the typed text.
public nonisolated struct PickerSaveName {
    public nonisolated init() {}
    /// The typed text at its last `/`: the part before names a folder to
    /// go to (relative to the folder shown, or `~/...`, or `/...`), the
    /// rest is the name. No `/`: no folder.
    public static func split(_ text: String) -> (folder: String?, name: String) {
        guard let slash = text.lastIndex(of: "/") else { return (nil, text) }
        let folder = String(text[...slash])
        return (folder, String(text[text.index(after: slash)...]))
    }

    /// Where the folder part of a typed name leads from `directory`.
    public static func folder(_ part: String, from directory: URL, home: URL) -> URL {
        if part == "~/" || part == "~" { return home }
        if part.hasPrefix("~/") { return home.appendingPathComponent(String(part.dropFirst(2)), isDirectory: true) }
        if part.hasPrefix("/") { return URL(fileURLWithPath: part, isDirectory: true) }
        return directory.appendingPathComponent(part, isDirectory: true)
    }

    /// The file name saved for `typed`: trimmed, with the chosen type's
    /// first extension unless the name already ends in one the filter
    /// allows. Nil for a name that cannot be a file.
    public static func fileName(_ typed: String, filter: PickerFilter, type index: Int) -> String? {
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard isValid(name) else { return nil }
        guard !filter.isAny, filter.types.indices.contains(index) else { return name }
        if filter.accepts(name) { return name }
        guard let ext = filter.types[index].extensions.first else { return name }
        return name + "." + ext
    }

    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
    }

    /// UTF-16 length of `name` without its extension: the part of a
    /// prefilled name that is selected, so typing replaces only the name.
    public static func selectionLength(_ name: String) -> Int {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name.count > ext.count + 1 else { return name.utf16.count }
        return name.utf16.count - ext.utf16.count - 1
    }
}

/// Asks before a save replaces an existing file. The dialogs lead's
/// CmuxDialog (R96) is not in cmux-next yet, so the picker ships a
/// temporary implementation that asks inside the palette
/// (``PalettePageOverwriteConfirmation``); a CmuxDialog conformer replaces
/// it without changing the picker.
public protocol PickerOverwriteConfirming {
    /// The effect of choosing `url`, which exists: ask, then run `replace`,
    /// or show `cancel` (the save page again, with the typed name).
    func confirm(replacing url: URL, replace: @escaping @MainActor () -> Void, cancel: PalettePageSpec) -> PaletteEffect
}

/// The temporary confirmation: a palette page with Replace and Cancel.
public struct PalettePageOverwriteConfirmation: PickerOverwriteConfirming {
    public init() {}

    public func confirm(replacing url: URL, replace: @escaping @MainActor () -> Void, cancel: PalettePageSpec) -> PaletteEffect {
        let section = PaletteSection(id: "confirm", title: "", order: 0)
        let question = PaletteItem(id: "confirm.question", title: PickerStrings.replaceQuestion(url.lastPathComponent),
                                   subtitle: PickerStrings.replaceDetail, symbol: "exclamationmark.triangle", section: section,
                                   isEnabled: false, primary: PaletteCommand(id: "none", title: "", effect: .performKeepingOpen {}),
                                   frecencyKey: nil)
        let replaceRow = PaletteItem(id: "confirm.replace", title: PickerStrings.replace, symbol: "arrow.triangle.2.circlepath",
                                     section: section,
                                     primary: PaletteCommand(id: "replace", title: PickerStrings.replace, isDestructive: true,
                                                             effect: .perform(replace)),
                                     frecencyKey: nil)
        let cancelRow = PaletteItem(id: "confirm.cancel", title: PickerStrings.cancel, symbol: "xmark", section: section,
                                    primary: PaletteCommand(id: "cancel", title: PickerStrings.cancel, effect: .replace(cancel)),
                                    frecencyKey: nil)
        var page = PalettePageSpec(id: "picker.confirm", title: cancel.title, placeholder: PickerStrings.replaceQuestion(url.lastPathComponent),
                                   symbol: "exclamationmark.triangle",
                                   providers: [StaticPaletteProvider(id: "picker.confirm", items: [question, cancelRow, replaceRow])],
                                   keepsSectionOrder: true, onCancel: cancel.onCancel)
        // Return on the page as it opens keeps the file: Cancel is selected.
        page.emptyQuerySelectionID = "confirm.cancel"
        return .replace(page)
    }
}
