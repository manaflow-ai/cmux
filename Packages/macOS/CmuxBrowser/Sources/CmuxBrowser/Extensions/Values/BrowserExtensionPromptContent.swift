public import Foundation

/// The content of a cmux extension sheet: a Chromium install or permission
/// prompt, or the consent an automation request needs.
///
/// Follows design spec §3a: the question as the title, who asked (for
/// automation), the exact target (extension name or folder), the permission
/// list, then Cancel as the default (Escape and Return) and a non-default,
/// verb-named accept button, so a grant is never the default action.
public struct BrowserExtensionPromptContent: Equatable, Sendable {
    /// The sheet title (a question).
    public var title: String
    /// Who asked, for automation requests ("A cmux CLI command wants to …"); nil for Chromium prompts.
    public var requester: String?
    /// The exact target: the extension name, or the folder for load unpacked.
    public var target: String
    /// The heading above ``permissions`` ("It can:"), or the no-access sentence when there are none.
    public var permissionsHeading: String
    /// What the extension can do.
    public var permissions: [BrowserExtensionInstallPrompt.Permission]
    /// A closing note, or nil.
    public var note: String?
    /// The accept button title (a verb, never the default button).
    public var acceptTitle: String
    /// The decline button title (the default button).
    public var cancelTitle: String

    /// Creates sheet content directly.
    public init(
        title: String, requester: String? = nil, target: String, permissionsHeading: String,
        permissions: [BrowserExtensionInstallPrompt.Permission] = [], note: String? = nil,
        acceptTitle: String, cancelTitle: String
    ) {
        self.title = title
        self.requester = requester
        self.target = target
        self.permissionsHeading = permissionsHeading
        self.permissions = permissions
        self.note = note
        self.acceptTitle = acceptTitle
        self.cancelTitle = cancelTitle
    }

    /// The content for a prompt Chromium raised (Web Store, `chrome.permissions`, re-enable, repair).
    ///
    /// - Parameter prompt: Chromium's prompt.
    public init(prompt: BrowserExtensionInstallPrompt) {
        let name = prompt.name
        requester = nil
        target = name
        permissions = prompt.permissions
        permissionsHeading = Self.heading(hasPermissions: !prompt.permissions.isEmpty)
        note = nil
        switch prompt.kind {
        case .permissions:
            title = String(localized: "browser.extension.prompt.permissionsTitle",
                           defaultValue: "\u{201C}\(name)\u{201D} wants more access", bundle: .module)
            acceptTitle = String(localized: "browser.extension.prompt.allow", defaultValue: "Allow", bundle: .module)
            cancelTitle = String(localized: "browser.extension.prompt.deny", defaultValue: "Deny", bundle: .module)
        case .reEnable:
            title = String(localized: "browser.extension.prompt.reEnableTitle",
                           defaultValue: "Turn on \u{201C}\(name)\u{201D} again?", bundle: .module)
            acceptTitle = String(localized: "browser.extension.prompt.enable", defaultValue: "Enable", bundle: .module)
            cancelTitle = String(localized: "browser.extension.prompt.cancel", defaultValue: "Cancel", bundle: .module)
        case .repair:
            title = String(localized: "browser.extension.prompt.repairTitle",
                           defaultValue: "Repair \u{201C}\(name)\u{201D}?", bundle: .module)
            acceptTitle = String(localized: "browser.extension.prompt.repair", defaultValue: "Repair", bundle: .module)
            cancelTitle = String(localized: "browser.extension.prompt.cancel", defaultValue: "Cancel", bundle: .module)
        case .install, .externalInstall, .remoteInstall, .other:
            title = String(localized: "browser.extension.prompt.addTitle", defaultValue: "Add \u{201C}\(name)\u{201D}?", bundle: .module)
            acceptTitle = String(localized: "browser.extension.prompt.add", defaultValue: "Add extension", bundle: .module)
            cancelTitle = String(localized: "browser.extension.prompt.cancel", defaultValue: "Cancel", bundle: .module)
        }
    }

    /// The consent content for an automation request (CLI or socket) that
    /// would widen what an extension can reach.
    ///
    /// - Parameters:
    ///   - operation: The requested operation.
    ///   - name: The extension name, or the folder for load unpacked.
    ///   - permissions: What the extension can do, when known (from its manifest).
    public init(
        automation operation: BrowserExtensionOperation, name: String,
        permissions: [BrowserExtensionInstallPrompt.Permission] = []
    ) {
        target = name
        self.permissions = permissions
        permissionsHeading = Self.heading(hasPermissions: !permissions.isEmpty)
        cancelTitle = String(localized: "browser.extension.prompt.cancel", defaultValue: "Cancel", bundle: .module)
        note = String(localized: "browser.extension.consent.note",
                      defaultValue: "Allow this only if you started the command.", bundle: .module)
        switch operation {
        case .loadUnpacked:
            title = String(localized: "browser.extension.consent.loadTitle", defaultValue: "Load an unpacked extension?", bundle: .module)
            requester = String(localized: "browser.extension.consent.loadRequester",
                               defaultValue: "A cmux CLI command wants to load an unpacked extension into this browser profile.", bundle: .module)
            acceptTitle = String(localized: "browser.extension.consent.load", defaultValue: "Load", bundle: .module)
        case .enable, .reload:
            title = String(localized: "browser.extension.consent.enableTitle", defaultValue: "Turn on \u{201C}\(name)\u{201D}?", bundle: .module)
            requester = String(localized: "browser.extension.consent.enableRequester",
                               defaultValue: "A cmux CLI command wants to turn on this extension.", bundle: .module)
            acceptTitle = String(localized: "browser.extension.prompt.enable", defaultValue: "Enable", bundle: .module)
        default:
            title = String(localized: "browser.extension.consent.runTitle",
                           defaultValue: "Run \u{201C}\(name)\u{201D} on this page?", bundle: .module)
            requester = String(localized: "browser.extension.consent.runRequester",
                               defaultValue: "A cmux CLI command wants to run this extension, which gives it access to the current page.", bundle: .module)
            acceptTitle = String(localized: "browser.extension.consent.run", defaultValue: "Run", bundle: .module)
        }
    }

    static func heading(hasPermissions: Bool) -> String {
        hasPermissions
            ? String(localized: "browser.extension.prompt.canHeading", defaultValue: "It can:", bundle: .module)
            : String(localized: "browser.extension.prompt.noPermissions", defaultValue: "It needs no special access.", bundle: .module)
    }
}
