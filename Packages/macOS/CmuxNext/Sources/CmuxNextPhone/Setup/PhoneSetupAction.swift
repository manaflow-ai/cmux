public import Foundation

/// A button on the setup screen. Every step has at least one, so the screen
/// is never a dead end.
public enum PhoneSetupAction: Sendable, Hashable {
    /// Opens Xcode's page in the Mac App Store.
    case openAppStore
    /// Opens Apple's Xcode page (betas, older versions, the website download).
    case openXcodeWebsite
    /// Opens the installed Xcode at this path so it finishes its own setup.
    case openXcode(String)
    case downloadIOS
    case cancelDownload
    case createIPhone
    case checkAgain
    /// Opens the Android Studio download page.
    case getAndroidStudio

    /// The page an action opens, for the actions that open one.
    public var url: URL? {
        switch self {
        case .openAppStore: URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")
        case .openXcodeWebsite: URL(string: "https://developer.apple.com/xcode/")
        case .getAndroidStudio: URL(string: "https://developer.android.com/studio")
        case .openXcode(let path): URL(fileURLWithPath: path)
        case .downloadIOS, .cancelDownload, .createIPhone, .checkAgain: nil
        }
    }
}
