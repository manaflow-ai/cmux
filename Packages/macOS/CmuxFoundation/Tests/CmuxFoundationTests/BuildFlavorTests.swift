import Testing

@testable import CmuxFoundation

@Suite struct BuildFlavorTests {
    @Test func devNameTokenWins() {
        #expect(
            BuildFlavor.detect(bundleName: "cmux DEV noqdlg", bundleIdentifier: "com.cmuxterm.app")
                == .dev
        )
    }

    @Test func devTokenBeatsNightlyToken() {
        #expect(
            BuildFlavor.detect(bundleName: "cmux DEV nightly", bundleIdentifier: "com.cmuxterm.app")
                == .dev
        )
    }

    @Test func debugLikeBundleIdentifierIsDev() {
        #expect(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.debug")
                == .dev
        )
        #expect(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.debug.mytag")
                == .dev
        )
    }

    @Test func nightlyBundleIdentifier() {
        #expect(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.nightly")
                == .nightly
        )
        #expect(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.nightly.x")
                == .nightly
        )
    }

    @Test func nightlyNameToken() {
        #expect(
            BuildFlavor.detect(bundleName: "cmux NIGHTLY", bundleIdentifier: "com.cmuxterm.app")
                == .nightly
        )
    }

    @Test func defaultsToStable() {
        #expect(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app")
                == .stable
        )
    }
}
