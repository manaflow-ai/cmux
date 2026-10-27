// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Testing

@Suite struct CuaTargetPolicyTests {
    @Test(arguments: [
        "com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.test",
        "com.cmuxterm.other-build", "com.cmuxterm.cua.dev",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.mitchellh.ghostty",
        "org.alacritty", "com.raphaelamorim.rio", "dev.commandline.waveterm", "dev.waveterm.waveterm",
        "co.zeit.hyper", "co.vercel.hyper", "org.tabby",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.dashlane.Dashlane",
        "com.lastpass.LastPass", "com.nordpass.NordPass", "com.nordpass.macos", "me.proton.pass",
        "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.LocalAuthenticationRemoteService",
        "com.apple.CoreAuthentication.agent", "com.apple.coreautha",
        "com.apple.systempreferences", "com.apple.loginwindow",
    ])
    func protectedAppsAreDenied(bundleID: String) {
        #expect(!CuaTargetPolicy().allows(bundleID: bundleID))
    }

    @Test(arguments: ["com.apple.TextEdit", "com.apple.Safari", "org.mozilla.firefox"])
    func ordinaryAppsAreAllowed(bundleID: String) {
        #expect(CuaTargetPolicy().allows(bundleID: bundleID))
    }

    @Test func exactAllowListUnlocksTaggedBuildsAndTerminals() {
        let policy = CuaTargetPolicy(allowedBundleIDs:
            " COM.CMUXTERM.APP.DEBUG.TEST, com.apple.Terminal\ncom.apple.Terminal ")
        #expect(policy.allows(bundleID: "com.cmuxterm.app.debug.test"))
        #expect(policy.allows(bundleID: "com.apple.Terminal"))
        #expect(!policy.allows(bundleID: "com.cmuxterm.app.debug.other"))
        #expect(!policy.allows(bundleID: "com.mitchellh.ghostty"))
    }

    @Test func wildcardsNeverUnlockTargets() {
        let policy = CuaTargetPolicy(allowedBundleIDs: "*, com.cmuxterm.*, com.apple.Term*")
        #expect(!policy.allows(bundleID: "com.cmuxterm.app.debug.test"))
        #expect(!policy.allows(bundleID: "com.apple.Terminal"))
    }

    @Test(arguments: [
        "com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.cua.dev",
        "com.apple.keychainaccess", "com.1password.1password", "com.apple.SecurityAgent",
    ])
    func hardDenialsSurviveTheAllowList(bundleID: String) {
        #expect(!CuaTargetPolicy(allowedBundleIDs: bundleID).allows(bundleID: bundleID))
    }

    @Test(arguments: ["Terminal", "Wave", "1Password", "SecurityAgent", "coreautha"])
    func resolvedNamesProtectAlternateBundleIDs(name: String) {
        #expect(!CuaTargetPolicy().allows(bundleID: "example.alternate-build", appName: name))
    }

    @Test func embeddingHostNeedsAnExactOverride() {
        let host = "example.agent-host"
        #expect(!CuaTargetPolicy(hostBundleID: host).allows(bundleID: host))
        #expect(CuaTargetPolicy(allowedBundleIDs: host, hostBundleID: host).allows(bundleID: host))
    }
}
