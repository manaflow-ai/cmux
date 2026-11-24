import CmuxNextCompat
import Foundation
import Testing

/// A `cmux app try` copy never looks inside another app's container (Leo 2026-11-22, a try copy's notification:
/// "Data Access Blocked: "cmux try-feat-agent-send-pop-f03f49" tried to access your data from other apps and was
/// blocked." "weird stuff"). The copy is known by the `.side-` part side-instance.sh adds to its bundle id.
@Suite struct OtherAppContainersTests {
    @Test("A side instance's bundle id", arguments: [
        ("com.cmuxterm.app.nightly.side-try-feat-agent-send-pop-f03f49-1a2b3c", true),
        ("com.cmuxterm.app.side-pr-50307-abcdef", true),
        ("com.cmuxterm.app.debug.feat-x.side-look-12ab56", true),
    ] as [(String, Bool)])
    func sideInstance(bundleID: String, expected: Bool) {
        #expect(OtherAppContainers.isSideInstance(bundleID: bundleID) == expected)
    }

    @Test("Not a side instance", arguments: [
        "com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.side-panel", "side-x-abcdef.example", "",
    ])
    func notSideInstance(bundleID: String) {
        #expect(!OtherAppContainers.isSideInstance(bundleID: bundleID))
        #expect(!OtherAppContainers.isSideInstance(bundleID: nil))
    }

    @Test func containersAreKnownInAnyHome() {
        let home = URL(fileURLWithPath: "/tmp/fixture-home", isDirectory: true)
        #expect(OtherAppContainers.contains(home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")))
        #expect(OtherAppContainers.contains(home.appending(path: "Library/Group Containers/7TQL462TU8.com.techsmith.snagit/Snagit/Autosave")))
        #expect(!OtherAppContainers.contains(home.appending(path: "Library/Safari/History.db")))
        #expect(!OtherAppContainers.contains(home.appending(path: "Library/Application Support/Google/Chrome")))
        #expect(!OtherAppContainers.mayLook(at: home.appending(path: "Library/Containers/com.apple.screencapture"), readsContainers: false))
        #expect(OtherAppContainers.mayLook(at: home.appending(path: "Library/Application Support/Google/Chrome"), readsContainers: false))
        #expect(OtherAppContainers.mayLook(at: home.appending(path: "Library/Containers/com.apple.screencapture"), readsContainers: true))
    }
}
