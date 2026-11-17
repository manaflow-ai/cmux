// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteHost
import Testing

/// Only System Settings' Quit & Reopen keeps the host; every other quit is the person's.
@Suite struct RemoteHostQuitTests {
    @Test func systemSettingsQuitAndReopenKeepsTheHost() {
        #expect(RemoteHost.isQuitAndReopen(senderBundleID: "com.apple.systempreferences"))
        #expect(RemoteHost.isQuitAndReopen(senderBundleID: "com.apple.Settings"))
    }

    @Test func anyOtherQuitIsHonored() {
        for sender in ["com.apple.ActivityMonitor", "com.apple.loginwindow", "com.apple.Terminal", "com.cmuxterm.app"] {
            #expect(!RemoteHost.isQuitAndReopen(senderBundleID: sender))
        }
        #expect(!RemoteHost.isQuitAndReopen(senderBundleID: nil))
    }
}
