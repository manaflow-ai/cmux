import Foundation

/// Localized strings of CmuxNextRemoteLocalhost (Resources/Localizable.xcstrings).
enum Strings {
    static func errorTitle(target: String, machine: String) -> String {
        String(localized: "remoteLocalhost.error.title", defaultValue: "Can’t reach \(target) on \(machine)", bundle: .localizedModule)
    }

    static func errorRefused(_ machine: String) -> String {
        String(localized: "remoteLocalhost.error.refused",
               defaultValue: "Nothing is listening on that port of \(machine). Start the server there, or check the port.", bundle: .localizedModule)
    }

    static func errorUnsupported(_ machine: String) -> String {
        String(localized: "remoteLocalhost.error.unsupported",
               defaultValue: "cmux on \(machine) can't forward localhost. Update that machine to use its localhost here.",
               bundle: .localizedModule)
    }

    static func errorDisabled(_ machine: String) -> String {
        String(localized: "remoteLocalhost.error.disabled",
               defaultValue: "Localhost forwarding is turned off on \(machine) (server.loopback_forward in cmux-tui.json).", bundle: .localizedModule)
    }

    static func errorPortNotAllowed(_ machine: String) -> String {
        String(localized: "remoteLocalhost.error.portNotAllowed", defaultValue: "\(machine) does not allow forwarding to this port.",
               bundle: .localizedModule)
    }

    static func errorUnavailable(_ machine: String) -> String {
        String(localized: "remoteLocalhost.error.unavailable",
               defaultValue: "cmux is not connected to \(machine). It reconnects by itself; reload when the machine is back.", bundle: .localizedModule)
    }

    static func errorOther(_ machine: String) -> String {
        String(localized: "remoteLocalhost.error.other", defaultValue: "\(machine) refused the connection.", bundle: .localizedModule)
    }

    static func errorFooter(_ machine: String) -> String {
        String(localized: "remoteLocalhost.error.footer", defaultValue: "In this tab, localhost is \(machine), not this Mac.", bundle: .localizedModule)
    }
}
