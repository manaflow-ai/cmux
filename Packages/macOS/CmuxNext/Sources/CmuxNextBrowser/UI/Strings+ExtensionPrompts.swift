import Foundation

/// Strings of extension install and permission prompts and of the omnibox
/// keyword chip.
extension Strings {
    static func extensionAddTitle(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.addTitle", defaultValue: "Add “\(name)”?", bundle: .localizedModule)
    }
    static func extensionPermissionsTitle(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.permissionsTitle", defaultValue: "“\(name)” wants more access", bundle: .localizedModule)
    }
    static func extensionReEnableTitle(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.reEnableTitle", defaultValue: "Turn on “\(name)” again?", bundle: .localizedModule)
    }
    static func extensionRepairTitle(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.repairTitle", defaultValue: "Repair “\(name)”?", bundle: .localizedModule)
    }
    static var extensionCanHeading: String {
        String(localized: "browser.extensionPrompt.canHeading", defaultValue: "It can:", bundle: .localizedModule)
    }
    static var extensionNoPermissions: String {
        String(localized: "browser.extensionPrompt.noPermissions", defaultValue: "It needs no special access.", bundle: .localizedModule)
    }
    static var extensionAdd: String {
        String(localized: "browser.extensionPrompt.add", defaultValue: "Add Extension", bundle: .localizedModule)
    }
    static var extensionAllow: String {
        String(localized: "browser.extensionPrompt.allow", defaultValue: "Allow", bundle: .localizedModule)
    }
    static var extensionTurnOn: String {
        String(localized: "browser.extensionPrompt.turnOn", defaultValue: "Turn On", bundle: .localizedModule)
    }
    static var extensionRepair: String {
        String(localized: "browser.extensionPrompt.repair", defaultValue: "Repair", bundle: .localizedModule)
    }
    static var extensionDeny: String {
        String(localized: "browser.extensionPrompt.deny", defaultValue: "Deny", bundle: .localizedModule)
    }
    static var extensionCancel: String {
        String(localized: "browser.extensionPrompt.cancel", defaultValue: "Cancel", bundle: .localizedModule)
    }
    static func extensionAdded(_ name: String) -> String {
        String(localized: "browser.extensionPrompt.added",
               defaultValue: "“\(name)” was added. Pin it from the Extensions menu.", bundle: .localizedModule)
    }
}
