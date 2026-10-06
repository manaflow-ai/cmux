import Foundation

/// The picker's text (Localizable.xcstrings, keys `picker.*`).
nonisolated enum PickerStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var useThisFolder: String { text("picker.useThisFolder", "Use This Folder") }
    static func openSelected(_ count: Int) -> String { String(format: text("picker.openSelected", "Open %lld Selected"), count) }
    static func showMore(_ count: Int) -> String { String(format: text("picker.showMore", "Show More (%lld)"), count) }
    static var permissionDenied: String { text("picker.notice.permission", "cmux can’t read this folder") }
    static var permissionDetail: String { text("picker.notice.permissionDetail", "macOS denied access. Allow cmux in System Settings.") }
    static var openPrivacySettings: String { text("picker.openPrivacySettings", "Open Privacy Settings") }
    static var notFound: String { text("picker.notice.notFound", "This folder does not exist") }
    static var empty: String { text("picker.notice.empty", "Nothing to choose here") }
    static var unreadable: String { text("picker.notice.unreadable", "cmux couldn’t read this folder") }
    static var showAllFiles: String { text("picker.allFiles", "Show All Files") }
    static func showOnly(_ types: String) -> String { String(format: text("picker.onlyTypes", "Show Only %@"), types) }
    static var newFolder: String { text("picker.newFolder", "New Folder…") }
    static var folderName: String { text("picker.folderName", "Folder name") }
    static func createFolder(_ name: String) -> String { String(format: text("picker.createFolder", "Create “%@”"), name) }
    static func save(_ name: String) -> String { String(format: text("picker.save", "Save “%@”"), name) }
    static func saveAs(_ type: String, _ ext: String) -> String {
        String(format: text("picker.saveAs", "Save as %1$@ (.%2$@)"), type, ext)
    }
    static var typeAName: String { text("picker.typeAName", "Type a file name") }
    static var namePlaceholder: String { text("picker.namePlaceholder", "Name") }
    static var chooseFolder: String { text("picker.placeholder.folder", "Choose a folder") }
    static var chooseFile: String { text("picker.placeholder.file", "Choose a file") }
    static var chooseItem: String { text("picker.placeholder.item", "Choose a file or folder") }
    static var choose: String { text("picker.choose", "Choose") }
    static var openFolder: String { text("picker.openFolder", "Open Folder") }
    static var select: String { text("picker.select", "Add to Selection") }
    static var deselect: String { text("picker.deselect", "Remove from Selection") }
    static var selected: String { text("picker.selected", "Selected") }
    static var gitRepository: String { text("picker.git", "Git") }
    static func replaceQuestion(_ name: String) -> String {
        String(format: text("picker.replaceQuestion", "“%@” already exists. Replace it?"), name)
    }
    static var replaceDetail: String { text("picker.replaceDetail", "Replacing it overwrites its contents.") }
    static var replace: String { text("picker.replace", "Replace") }
    static var cancel: String { text("picker.cancel", "Cancel") }
    static func explainer(_ folder: String) -> String {
        String(format: text("picker.explainer.title", "macOS will ask before cmux opens %@"), folder)
    }
    static var explainerDetail: String {
        text("picker.explainer.detail", "cmux reads a protected folder only when you open it. You can change this later in System Settings.")
    }
    static var continueTitle: String { text("picker.explainer.continue", "Continue") }
    static var goBack: String { text("picker.explainer.back", "Go Back") }
    static var markdownType: String { text("picker.type.markdown", "Markdown") }
    static var locations: String { text("picker.locations", "Locations") }
    static var home: String { text("picker.location.home", "Home") }
    static var openHint: String { text("picker.hint.open", "Type to filter, or start with / to type a path") }
    static var saveHint: String { text("picker.hint.save", "Type a name, or a folder path ending in /") }
    static func goTo(_ path: String) -> String { String(format: text("picker.goTo", "Go to %@"), path) }
    static func noMatch(_ path: String) -> String { String(format: text("picker.noMatch", "Nothing in %@ starts with that"), path) }

    static func area(_ area: PickerPrivacy.Area) -> String {
        switch area {
        case .desktop: text("picker.area.desktop", "Desktop")
        case .documents: text("picker.area.documents", "Documents")
        case .downloads: text("picker.area.downloads", "Downloads")
        case .iCloudDrive: text("picker.area.iCloudDrive", "iCloud Drive")
        case .volumes: text("picker.area.volume", "this volume")
        }
    }
}
