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
    /// Import from Another Browser… (cx-d0d.65): the browser's export steps,
    /// then the files it exported, into `profile` (nil: the default profile).
    /// Reads no browser's own data, so it works where detection finds nothing.
    func importFromFiles(into profile: String?)
    /// Browsers on this Mac whose profile folder cmux has no grant for yet;
    /// listed by name only, nothing inside is read. Empty when import reads
    /// folders without a grant.
    func browsersAwaitingAccess() async -> [ImportBrowser]
    /// The open panel at `browser`'s profile folder: true once the person
    /// picked that folder (kept as a security-scoped bookmark).
    func requestFolderAccess(for browser: ImportBrowser) async -> Bool
    /// The profile folder a grant for `browser` must pick (the explainer names it).
    func accessFolder(for browser: ImportBrowser) -> URL?
    /// Import Passwords from CSV… into `profile` (nil: the default profile):
    /// the person's own export, no Keychain.
    func importPasswordsFromCSV(into profile: String?)
    /// The cmux browser profiles an import row can go into instead of its
    /// own new profile, in display order.
    func importTargets() async -> [ImportTargetChoice]
    /// Sources an earlier import put into another cmux profile than their
    /// own (`BrowserSourceProfile.id` to that profile's id): the row starts there.
    func earlierImportTargets() async -> [String: String]

    // Computer use
    /// The helper app's grants, or nil when this build has no computer use.
    var computerUsePermissions: (any ComputerUsePermissionSource)? { get }
}

public extension OnboardingServices {
    var computerUsePermissions: (any ComputerUsePermissionSource)? { nil }
    func canImportPasswords() async -> Bool { false }
    func importFromFiles(into profile: String?) {}
    func browsersAwaitingAccess() async -> [ImportBrowser] { [] }
    func requestFolderAccess(for browser: ImportBrowser) async -> Bool { false }
    func accessFolder(for browser: ImportBrowser) -> URL? { nil }
    func importPasswordsFromCSV(into profile: String?) {}
    func importTargets() async -> [ImportTargetChoice] { [] }
    func earlierImportTargets() async -> [String: String] { [:] }
}

/// A cmux browser profile an import row can go into.
public struct ImportTargetChoice: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// System Settings deep links.
public extension URL {
    /// Privacy & Security > Full Disk Access.
    /// (A literal a test parses; /dev/null stands in rather than a trap.)
    static let systemSettingsFullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        ?? URL(fileURLWithPath: "/dev/null")
}
