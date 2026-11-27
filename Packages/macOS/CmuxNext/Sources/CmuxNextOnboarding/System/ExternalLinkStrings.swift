import Foundation

/// The `ssh://` link question's text: classic cmux's `cmux://ssh` confirmation keys and wording
/// (Sources/AppDelegate+CmuxSSHURL.swift), with its translations.
nonisolated enum ExternalLinkStrings {
    static var sshTitle: String { String(localized: "dialog.sshURL.title", defaultValue: "Open SSH Workspace in cmux?", bundle: .localizedModule) }
    static func sshMessage(_ target: String) -> String {
        String(format: String(localized: "dialog.sshURL.message", defaultValue: "An external link wants to open \"%@\" in cmux. Do you want to open this SSH workspace?\n\nIf you did not initiate this request, it may represent an attempted attack on your system. Only continue if you explicitly started this action.", bundle: .localizedModule), target)
    }
    static func sshTarget(_ target: String) -> String { String(format: String(localized: "dialog.sshURL.targetLabel", defaultValue: "SSH target: %@", bundle: .localizedModule), target) }
    static var sshCommandLabel: String { String(localized: "dialog.sshURL.commandLabel", defaultValue: "Command preview:", bundle: .localizedModule) }
    static var sshAlwaysAllow: String { String(localized: "dialog.sshURL.alwaysAllow", defaultValue: "Always allow this host", bundle: .localizedModule) }
    static var sshConnect: String { String(localized: "dialog.sshURL.connect", defaultValue: "Connect", bundle: .localizedModule) }
}
