import AppKit

/// The app's file picker as a made-ahead panel (``ReusableOpenPanel``).
extension NSOpenPanel: ReusableOpenPanel {
    var isFreeForReuse: Bool { !isVisible && sheetParent == nil }

    func resetChoices() {
        allowsMultipleSelection = false
        canChooseDirectories = false
        canChooseFiles = true
        resolvesAliases = true
        allowedContentTypes = []
    }
}
