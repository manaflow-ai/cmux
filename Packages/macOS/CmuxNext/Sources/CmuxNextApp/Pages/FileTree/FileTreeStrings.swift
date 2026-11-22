import Foundation

nonisolated enum FileTreeStrings {
    static var title: String { String(localized: "fileTree.title", defaultValue: "Files", table: "Handlers", bundle: .module.inAppLanguage) }
    static var noFolder: String {
        String(localized: "fileTree.noFolder", defaultValue: "This tab has no folder. Open Files from the chat's header again.",
               table: "Handlers", bundle: .module.inAppLanguage)
    }
    /// A failed listing. A folder in no git repository is no failure: the session host lists it from the disk.
    static var unavailable: String {
        String(localized: "fileTree.unavailable",
               defaultValue: "The files could not be listed. Choose Refresh from the right-click menu to try again.",
               table: "Handlers", bundle: .module.inAppLanguage)
    }
}
