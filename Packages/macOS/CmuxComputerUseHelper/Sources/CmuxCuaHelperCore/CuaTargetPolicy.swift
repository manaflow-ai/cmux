// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The legacy target policy, extended to all cmux builds and sensitive apps.
struct CuaTargetPolicy: Sendable {
    private let allowed: Set<String>
    private let hostBundleID: String?

    init(allowedBundleIDs: String = "", hostBundleID: String? = nil) {
        allowed = Set(allowedBundleIDs.split { $0 == "," || $0.isWhitespace }
            .map { $0.lowercased() }.filter { !$0.contains("*") })
        self.hostBundleID = hostBundleID?.lowercased()
    }

    func allows(bundleID: String, appName: String = "") -> Bool {
        let bundle = bundleID.lowercased()
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !bundle.isEmpty else { return false }
        // As in legacy, no allow-list entry unlocks the driver or security UI.
        if bundle == "com.cmuxterm.app.computer-use" || bundle == "com.cmuxterm.cua"
            || bundle.hasPrefix("com.cmuxterm.cua.")
            || Self.securityBundles.contains(bundle)
            || Self.securityPrefixes.contains(where: bundle.hasPrefix)
            || Self.securityNames.contains(name) {
            return false
        }
        if bundle.hasPrefix("com.cmuxterm.") || name == "cmux" || name.hasPrefix("cmux ") {
            let prefix = "com.cmuxterm.app.debug."
            return bundle.hasPrefix(prefix) && bundle.count > prefix.count && allowed.contains(bundle)
        }
        if bundle == hostBundleID || Self.terminalBundles.contains(bundle)
            || bundle.hasPrefix("dev.warp.") || Self.terminalNames.contains(name) {
            return allowed.contains(bundle)
        }
        return true
    }

    private static let terminalBundles: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "com.mitchellh.ghostty", "org.alacritty",
        "com.raphaelamorim.rio", "dev.commandline.waveterm", "dev.waveterm.waveterm", "co.zeit.hyper",
        "co.vercel.hyper", "org.tabby",
    ]
    private static let terminalNames: Set<String> = [
        "terminal", "iterm", "iterm2", "warp", "warp preview", "kitty", "wezterm",
        "ghostty", "alacritty", "rio", "wave", "waveterm", "hyper", "tabby",
    ]
    private static let securityBundles: Set<String> = [
        "com.apple.keychainaccess", "com.apple.passwords", "com.bitwarden.desktop",
        "com.dashlane.dashlane", "com.lastpass.lastpass", "com.nordpass.nordpass",
        "me.proton.pass", "com.apple.securityagent", "com.apple.usernotificationcenter",
        "com.apple.localauthenticationremoteservice", "com.apple.coreautha",
        "com.apple.coreauthentication.agent", "com.apple.loginwindow",
        "com.apple.coreservicesuiagent", "com.apple.authorizationhost", "com.apple.systempreferences",
        "org.keepassxc.keepassxc", "com.hicknhacksoftware.macpass",
    ]
    private static let securityPrefixes = [
        "com.agilebits.onepassword", "com.1password.", "com.bitwarden.", "com.dashlane.",
        "com.lastpass.", "com.nordpass.", "com.nordvpn.nordpass", "com.apple.localauthentication.",
        "com.apple.authenticationservices.", "com.apple.coreauthentication.",
        "com.markmcguill.strongbox", "in.sinew.enpass", "com.keepersecurity.",
        "com.siber.roboform", "com.outercorner.secrets",
    ]
    private static let securityNames: Set<String> = [
        "keychain access", "passwords", "1password", "bitwarden", "dashlane", "lastpass",
        "nordpass", "proton pass", "securityagent", "usernotificationcenter",
        "localauthenticationremoteservice", "coreautha", "coreauthd", "loginwindow",
        "authorizationhost", "system settings", "system preferences", "cmux-cua", "cmux computer use",
        "keepassxc", "strongbox", "macpass", "enpass", "keeper", "roboform", "secrets",
    ]
}
