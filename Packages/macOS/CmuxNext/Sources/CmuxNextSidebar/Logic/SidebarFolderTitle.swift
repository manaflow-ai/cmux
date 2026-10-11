import Foundation

/// A Group by Folder header's title: the folder's last path component.
enum SidebarFolderTitle {
    static func title(_ folder: String) -> String {
        if folder.isEmpty { return Strings.noFolder }
        if folder == "~" || folder == "/" { return folder }
        return folder.split(separator: "/").last.map(String.init) ?? folder
    }
}
