public import AppKit
public import CmuxNextBrowserImport
public import Foundation

/// What the tool window (Import from Browser, Computer Use setup) needs
/// from the app. The App implements it over the importer and the helper
/// app; `MockOnboardingServices` runs the window alone (tests).
@MainActor
public protocol OnboardingServices: AnyObject {
    // Import
    func detectBrowsers() async -> [BrowserSource]
    func runImport(_ plan: ImportPlan, progress: @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary
    /// Whether this build can save imported passwords (the browser engine has the store).
    func canImportPasswords() async -> Bool
    /// The single confirmation before saved passwords are read: Touch ID or
    /// the Mac's password (LocalAuthentication). False when the person
    /// cancels or fails; nothing is read then.
    func authorizePasswordRead(reason: String) async -> Bool
    /// Opens a URL with the system (System Settings panes).
    func openExternal(_ url: URL)

    // Computer use
    /// The helper app's grants, or nil when this build has no computer use.
    var computerUsePermissions: (any ComputerUsePermissionSource)? { get }
}

public extension OnboardingServices {
    var computerUsePermissions: (any ComputerUsePermissionSource)? { nil }
    func canImportPasswords() async -> Bool { false }
}

/// System Settings deep links.
public extension URL {
    /// Privacy & Security > Full Disk Access.
    /// (A literal a test parses; /dev/null stands in rather than a trap.)
    static let systemSettingsFullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        ?? URL(fileURLWithPath: "/dev/null")
}
