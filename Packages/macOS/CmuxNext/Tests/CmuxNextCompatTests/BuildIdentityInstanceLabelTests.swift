import Testing
@testable import CmuxNextCompat

/// How a build names itself to other devices (the iPhone app lists each build on a Mac as its own
/// Mac): Stable carries no decoration, NIGHTLY and every other build say which they are.
@Suite struct BuildIdentityInstanceLabelTests {
    func label(_ bundleID: String?, tag: String? = nil) -> String? {
        BuildIdentity(bundleID: bundleID, bundledTag: tag).instanceLabel
    }

    @Test func theStableLaneIsUndecorated() {
        #expect(label("com.cmuxterm.app") == nil)
        #expect(label("com.cmuxterm.app.nightly.cmux-next-stable") == nil)
    }

    @Test func nightlySaysNightly() {
        #expect(label("com.cmuxterm.app.nightly") == "NIGHTLY")
    }

    @Test func otherBuildsNameTheirKindAndTag() {
        #expect(label("com.cmuxterm.app.debug.my-tag") == "DEV my-tag")
        #expect(label("com.cmuxterm.app.debug") == "DEV")
        #expect(label("com.cmuxterm.app.rc") == "RC")
        #expect(label("com.cmuxterm.app.staging.qa") == "STAGING qa")
        #expect(label("com.cmuxterm.app.nightly.cmux-next") == "NIGHTLY cmux-next")
        #expect(label("com.cmuxterm.app.somethingelse") == "DEV somethingelse")
        #expect(label(nil) == "DEV")
    }

    /// Stable and Nightly on one Mac read apart.
    @Test func stableAndNightlyDiffer() {
        #expect(label("com.cmuxterm.app.nightly.cmux-next-stable") != label("com.cmuxterm.app.nightly"))
    }
}
