import Foundation

/// Why a Cloud machine's link failed, with the next step. Keys live in
/// Resources/Cloud.xcstrings with every app locale (``CloudAppLinks/endedMessage(_:)``).
extension CloudStrings {
    /// A link resolver this build does not have (`CloudLinkError.unsupported`).
    static var linkUnsupported: String {
        String(localized: "cloud.link.unsupported",
               defaultValue: "This version of cmux can't connect to the Cloud machine this way. Update cmux, then click Connect.",
               table: "Cloud", bundle: .module)
    }

    /// Other users can open the link socket's folder or change one of its
    /// parents; `fix` is the `chmod` command that closes it.
    static func linkOpenDirectory(_ path: String, fix: String) -> String {
        String(format: String(localized: "cloud.link.openDirectory",
                              defaultValue: "cmux didn't connect because other users can open %1$@. Run `%2$@` in Terminal, then click Connect.",
                              table: "Cloud", bundle: .module), path, fix)
    }

    /// The connect answer or its socket failed a safety check (the check is in the log).
    static var linkCheckFailed: String {
        String(localized: "cloud.link.checkFailed",
               defaultValue: "cmux didn't connect: the Cloud app's answer for this machine failed a safety check. Click Connect to try again; if it keeps happening, run `cmux cloud diagnostics`.",
               table: "Cloud", bundle: .module)
    }

    /// The machine's carrier is in `state` (the Cloud server's word), not up.
    static func linkNotReady(_ state: String) -> String {
        String(format: String(localized: "cloud.link.notReady", defaultValue: "The machine's connection isn't ready yet (%@). Click Connect to try again.",
                              table: "Cloud", bundle: .module), state)
    }
}
