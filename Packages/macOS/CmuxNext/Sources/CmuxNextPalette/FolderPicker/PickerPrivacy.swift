public import Foundation

/// The folders macOS guards with a privacy prompt (Files and Folders):
/// reading one the first time asks the user. The picker reads one only
/// when the user opens it, shows its own explainer once before the first
/// such read, and never probes inside one it merely lists (no `.git`
/// check, no recursive or background listing).
public nonisolated struct PickerPrivacy {
    public nonisolated init() {}
    public enum Area: String, Equatable, Sendable {
        case desktop
        case documents
        case downloads
        case iCloudDrive
        case volumes
    }

    /// The protected area `path` is (or is inside), else nil.
    public static func area(of path: String, home: String = NSHomeDirectory()) -> Area? {
        let roots: [(String, Area)] = [
            (home + "/Desktop", .desktop), (home + "/Documents", .documents), (home + "/Downloads", .downloads),
            (home + "/Library/Mobile Documents", .iCloudDrive), ("/Volumes", .volumes),
        ]
        for (root, area) in roots where path == root || path.hasPrefix(root + "/") {
            // `/Volumes` itself only lists mounts; a volume inside it asks.
            if area == .volumes, path == root { return nil }
            return area
        }
        return nil
    }

    public static func isProtected(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        area(of: path, home: home) != nil
    }

    /// Home folders the listing never looks inside until the user opens
    /// them: the protected ones and the media and Library folders (a
    /// `.git` probe there could raise a prompt or wake a library).
    static let guardedHomeFolders = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"]

    /// Whether listing a folder may probe inside its child `path` (the
    /// `.git` check): not a guarded home folder, a mounted volume, or a
    /// protected area's root.
    public static func mayProbe(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if parent == home, guardedHomeFolders.contains(name) { return false }
        if parent == "/Volumes" { return false }
        if path == home + "/Library/Mobile Documents" { return false }
        return true
    }

    /// The System Settings pane where the user allows `area` again.
    public static func settingsURL(for area: Area?) -> URL {
        let anchor = switch area {
        case .desktop: "Privacy_DesktopFolder"
        case .documents: "Privacy_DocumentsFolder"
        case .downloads: "Privacy_DownloadsFolder"
        case .volumes: "Privacy_RemovableVolume"
        case .iCloudDrive, nil: "Privacy_FilesAndFolders"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
            ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
    }
}

/// Remembers that the picker showed its privacy explainer, so it shows
/// once per user, not once per folder or launch.
public protocol PickerExplainerMemory: AnyObject {
    var hasShownExplainer: Bool { get set }
}

/// The app's memory of the explainer: one user default.
public final class UserDefaultsPickerExplainerMemory: PickerExplainerMemory {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "picker.privacyExplainerShown") {
        self.defaults = defaults
        self.key = key
    }

    public var hasShownExplainer: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
