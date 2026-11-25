@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import Testing

/// #51115: only a tagged DEV build opens on the built-in display by default. cmux NEXT Nightly
/// and Stable carry a tag in their bundle id too (`com.cmuxterm.app.nightly.cmux-next`), and
/// must keep the usual placement.
@Suite struct LaunchDisplayBuildTests {
    static func display(_ bundleID: String, tag: String? = nil, _ environment: [String: String] = [:]) -> LaunchDisplay? {
        AppEnvironment.launchDisplay(environment, build: BuildIdentity(bundleID: bundleID, bundledTag: tag))
    }

    @Test func aTaggedDevBuildOpensOnTheBuiltInDisplay() {
        #expect(Self.display("com.cmuxterm.app.debug.51115.dev.builds.on.macbook", tag: "51115-dev-builds-on-macbook") == .builtIn)
    }

    @Test func nightlyStableRcAndReleaseKeepTheUsualPlacement() {
        #expect(Self.display("com.cmuxterm.app.nightly.cmux-next") == nil)
        #expect(Self.display("com.cmuxterm.app.nightly.cmux-next-stable") == nil)
        #expect(Self.display("com.cmuxterm.app.nightly") == nil)
        #expect(Self.display("com.cmuxterm.app.rc") == nil)
        #expect(Self.display("com.cmuxterm.app") == nil)
        #expect(Self.display("com.cmuxterm.app.staging.some-tag") == nil)
    }

    @Test func anUntaggedDevBuildKeepsTheUsualPlacement() {
        #expect(Self.display("com.cmuxterm.app.debug") == nil)
    }

    @Test func theVariableOverridesEitherWay() {
        #expect(Self.display("com.cmuxterm.app.debug.x", tag: "x", ["CMUX_NEXT_LAUNCH_DISPLAY": "off"]) == nil)
        #expect(Self.display("com.cmuxterm.app.nightly.cmux-next", ["CMUX_NEXT_LAUNCH_DISPLAY": "builtin"]) == .builtIn)
    }
}
