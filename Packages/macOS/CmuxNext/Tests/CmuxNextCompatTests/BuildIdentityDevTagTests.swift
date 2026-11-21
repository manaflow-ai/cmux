import CmuxNextCompat
import Testing

/// Only a tagged DEV or staging build has a dev tag (its cloud build space); NIGHTLY, cmux NEXT's NIGHTLY, RC,
/// release and untagged builds have none and send no `X-Cmux-Build-Space`.
@Suite struct BuildIdentityDevTagTests {
    @Test("A tagged dev build's tag", arguments: [
        ("com.cmuxterm.app.debug.feat-x", nil, "feat-x"),
        ("com.cmuxterm.app.debug", "My_Tag 2", "my-tag-2"),
        ("com.cmuxterm.app.staging.rel-check", nil, "rel-check"),
    ] as [(String, String?, String)])
    func tagged(bundleID: String, bundledTag: String?, expected: String) {
        #expect(BuildIdentity(bundleID: bundleID, bundledTag: bundledTag).devTag == expected)
    }

    @Test("No dev tag for nightly, release, RC, an untagged DEV build or no bundle", arguments: [
        "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app", "com.cmuxterm.app.rc",
        "com.cmuxterm.app.rc.cmux-next", "com.cmuxterm.app.debug", "",
    ])
    func untagged(bundleID: String) {
        #expect(BuildIdentity(bundleID: bundleID, bundledTag: nil).devTag == nil)
    }

    @Test("Every DEV build and a tagged staging build must have a build space of their own", arguments: [
        "com.cmuxterm.app.debug", "com.cmuxterm.app.debug.feat-x", "com.cmuxterm.app.debug.___", "com.cmuxterm.app.staging.rel-check",
    ])
    func needsBuildSpace(bundleID: String) {
        #expect(BuildIdentity(bundleID: bundleID, bundledTag: nil).needsBuildSpace)
    }

    @Test("Nightly, cmux NEXT, RC, release, untagged staging, other bundles and no bundle need none", arguments: [
        "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app", "com.cmuxterm.app.rc",
        "com.cmuxterm.app.rc.cmux-next", "com.cmuxterm.app.staging", "com.cmuxterm.app.debugger", "com.apple.dt.xctest.tool", "",
    ])
    func needsNoBuildSpace(bundleID: String) {
        #expect(!BuildIdentity(bundleID: bundleID, bundledTag: nil).needsBuildSpace)
    }
}
