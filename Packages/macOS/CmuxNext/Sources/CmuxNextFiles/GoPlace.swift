public import Foundation

/// The Go menu's fixed places and their Shift+Cmd keys.
public enum GoPlace: String, Sendable, CaseIterable {
    /// Shift+Cmd+H.
    case home
    /// Shift+Cmd+D.
    case desktop
    /// Shift+Cmd+O.
    case documents
    /// Opt+Cmd+L (Finder); Shift+Cmd+L here as well.
    case downloads
    /// Shift+Cmd+A.
    case applications
    /// Shift+Cmd+U.
    case utilities
    /// Shift+Cmd+C: the mounted volumes.
    case computer
    /// Shift+Cmd+I.
    case iCloudDrive

    /// Where the place is for a person whose home is `home`.
    public func url(home: URL) -> URL {
        switch self {
        case .home: home
        case .desktop: home.appendingPathComponent("Desktop", isDirectory: true)
        case .documents: home.appendingPathComponent("Documents", isDirectory: true)
        case .downloads: home.appendingPathComponent("Downloads", isDirectory: true)
        case .applications: URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .utilities: URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true)
        case .computer: URL(fileURLWithPath: "/Volumes", isDirectory: true)
        case .iCloudDrive: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        }
    }

    /// The place Shift+Cmd+`key` goes to, if any.
    public static func place(forShiftCommandKey key: String) -> GoPlace? {
        switch key.lowercased() {
        case "h": .home
        case "d": .desktop
        case "o": .documents
        case "l": .downloads
        case "a": .applications
        case "u": .utilities
        case "c": .computer
        case "i": .iCloudDrive
        default: nil
        }
    }
}
