import Foundation
import Testing
@testable import CmuxNextFiles

/// The Open With submenu's order (plans/cmux-next/files-finder-parity-DESIGN.md, 1).
struct OpenWithListTests {
    private static func app(_ name: String, _ id: String?) -> OpenWithApp {
        OpenWithApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), bundleID: id, name: name)
    }

    @Test func defaultFirstThenByName() {
        let code = Self.app("Visual Studio Code", "com.microsoft.VSCode")
        let safari = Self.app("Safari", "com.apple.Safari")
        let chrome = Self.app("Google Chrome", "com.google.Chrome")
        let list = OpenWithList(defaultApp: safari, apps: [code, safari, chrome])
        #expect(list.apps.map(\.name) == ["Safari", "Google Chrome", "Visual Studio Code"])
        #expect(list.apps.first?.isDefault == true)
        #expect(list.apps.dropFirst().allSatisfy { !$0.isDefault })
    }

    @Test func duplicatesByBundleIDKeepOne() {
        // Two copies of one app (Applications and a DMG mount): one row, the default's copy wins.
        let a = Self.app("Visual Studio Code", "com.microsoft.VSCode")
        var b = Self.app("Visual Studio Code", "com.microsoft.VSCode")
        b = OpenWithApp(url: URL(fileURLWithPath: "/Volumes/VSCode/Visual Studio Code.app"), bundleID: b.bundleID, name: b.name)
        let list = OpenWithList(defaultApp: a, apps: [b, a])
        #expect(list.apps.count == 1)
        #expect(list.apps.first?.url == a.url)
    }

    @Test func caseInsensitiveNumericNameOrder() {
        let list = OpenWithList(defaultApp: nil, apps: [Self.app("zed", "dev.zed"), Self.app("Xcode 2", "x2"),
                                                        Self.app("Xcode 10", "x10"), Self.app("BBEdit", "bb")])
        #expect(list.apps.map(\.name) == ["BBEdit", "Xcode 2", "Xcode 10", "zed"])
    }

    @Test func emptyListStillOffersOther() {
        let list = OpenWithList(defaultApp: nil, apps: [])
        #expect(list.apps.isEmpty)
        #expect(list.offersOther)
    }

    @Test func appsWithoutBundleIDsDedupeByPath() {
        let a = Self.app("Tool", nil)
        let list = OpenWithList(defaultApp: nil, apps: [a, a])
        #expect(list.apps.count == 1)
    }
}
