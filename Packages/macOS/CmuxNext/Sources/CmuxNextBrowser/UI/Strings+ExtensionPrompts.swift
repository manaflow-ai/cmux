import Foundation

/// Strings of extension install and permission prompts and of the omnibox
/// keyword chip.
extension Strings {
    static func extensionAddTitle(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.addTitle", defaultValue: "Add “\(name)”?", bundle: .l10n)
    }
    static func extensionPermissionsTitle(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.permissionsTitle", defaultValue: "“\(name)” wants more access", bundle: .l10n)
    }
    static func extensionReEnableTitle(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.reEnableTitle", defaultValue: "Turn on “\(name)” again?", bundle: .l10n)
    }
    static func extensionRepairTitle(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.repairTitle", defaultValue: "Repair “\(name)”?", bundle: .l10n)
    }
    static var extensionCanHeading: String {
        String(localized: "browser.extensionPrompt.canHeading", defaultValue: "It can:", bundle: .l10n)
    }
    static var extensionNoPermissions: String {
        String(localized: "browser.extensionPrompt.noPermissions", defaultValue: "It needs no special access.", bundle: .l10n)
    }
    static var extensionAdd: String {
        String(localized: "browser.extensionPrompt.add", defaultValue: "Add Extension", bundle: .l10n)
    }
    static var extensionAllow: String {
        String(localized: "browser.extensionPrompt.allow", defaultValue: "Allow", bundle: .l10n)
    }
    static var extensionTurnOn: String {
        String(localized: "browser.extensionPrompt.turnOn", defaultValue: "Turn On", bundle: .l10n)
    }
    static var extensionRepair: String {
        String(localized: "browser.extensionPrompt.repair", defaultValue: "Repair", bundle: .l10n)
    }
    static var extensionDeny: String {
        String(localized: "browser.extensionPrompt.deny", defaultValue: "Deny", bundle: .l10n)
    }
    static var extensionCancel: String {
        String(localized: "browser.extensionPrompt.cancel", defaultValue: "Cancel", bundle: .l10n)
    }
    static func extensionAdded(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.added",
               defaultValue: "“\(name)” was added. Pin it from the Extensions menu.", bundle: .l10n)
    }
}
