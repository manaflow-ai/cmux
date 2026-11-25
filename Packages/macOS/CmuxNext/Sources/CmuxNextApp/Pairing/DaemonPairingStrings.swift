import CmuxNextDesign
import Foundation

/// The pairing dialog (Resources/DaemonPairing.xcstrings).
enum DaemonPairingStrings {
    static let approveID = "approve"
    static let denyID = "deny"

    static var title: String {
        String(localized: "daemonPairing.title", defaultValue: "Allow a browser to control cmux?",
               table: "DaemonPairing", bundle: .module)
    }

    static func message(code: String) -> String {
        String(localized: "daemonPairing.message",
               defaultValue: "A browser page asked to connect to this cmux. Approve only if it shows the code \(code).",
               table: "DaemonPairing", bundle: .module)
    }

    static func peer(_ peer: String) -> String {
        String(localized: "daemonPairing.peer", defaultValue: "From: \(peer)", table: "DaemonPairing", bundle: .module)
    }

    static var detail: String {
        String(localized: "daemonPairing.detail",
               defaultValue: "It can then read and send your messages, open workspaces and type in terminals for 8 hours.",
               table: "DaemonPairing", bundle: .module)
    }

    static var approve: String {
        String(localized: "daemonPairing.approve", defaultValue: "Approve", table: "DaemonPairing", bundle: .module)
    }

    static var deny: String {
        String(localized: "daemonPairing.deny", defaultValue: "Deny", table: "DaemonPairing", bundle: .module)
    }

    /// Deny on Escape. Approve has no key.
    static func spec(code: String, peer: String) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: title, lines: [message(code: code)] + (peer.isEmpty ? [] : [Self.peer(peer)]) + [detail],
            buttons: [
                CmuxDialogButton(id: denyID, title: deny, role: .cancel),
                CmuxDialogButton(id: approveID, title: approve, role: .normal),
            ],
            identifier: identifier)
    }

    /// The dialog's accessibility identifier; automation may not press it.
    static let identifier = "cmux.dialog.daemonPairing"
}
