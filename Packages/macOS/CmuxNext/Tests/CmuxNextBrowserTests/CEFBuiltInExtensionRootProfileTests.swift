@testable import CmuxNextBrowser
import Foundation
import Testing

/// With the feature `chromiumAdBlockerAtFirstTab` on and a fork without `cmux_ext_load_command_line_async` (fork API
/// 41; no pinned fork has it, 2026-10-28), the built-in uBlock Origin went back to `--load-extension` with no sign:
/// Chromium then loads it into every profile it starts, its root `Default` profile too, which no cmux tab uses. The
/// first-seconds bench (step 92df0d13, Debug v2.2.3 with the feature on) found two uBlock background pages, each
/// writing its 49.5 MB filter engine and running its own extension renderer. Now the feature on a fork without the
/// call loads no built-in extension at all, unless the person turned `browser.builtInAdBlocker` on in cmux.json
/// (then the old start-time load, root profile included), and `debug.cef` says which way this Chromium went.
@MainActor @Suite(.serialized) struct CEFBuiltInExtensionRootProfileTests {
    private static let folder = "/Applications/cmux.app/Contents/Resources/Extensions/ublock-origin"

    @Test func theFeatureOnAnOldForkLoadsNoBuiltInExtension() {
        let loader = CEFBuiltInExtensionLoader()
        loader.featureOn = true
        #expect(loader.start([Self.folder], forkSupports: false) == .off)
        #expect(loader.loads.folders.isEmpty, "no profile loads it at its first tab either")
        let arguments = Self.arguments(loader.lastStart)
        #expect(!arguments.contains { $0.hasPrefix("load-extension=") }, "the root profile would get it: \(arguments)")
        #expect(!arguments.contains("disable-features=ExtensionDisableUnsupportedDeveloper"), "nothing unpacked loads: \(arguments)")
    }

    @Test func aPersonsChoiceKeepsTheStartTimeLoadOnAnOldFork() {
        let loader = CEFBuiltInExtensionLoader()
        loader.featureOn = true
        #expect(loader.start([Self.folder], forkSupports: false, personChose: true) == .atStart)
        #expect(Self.arguments(loader.lastStart).contains("load-extension=" + Self.folder))
    }

    @Test func theOtherWaysAreUnchanged() {
        let loader = CEFBuiltInExtensionLoader()
        #expect(loader.start([Self.folder], forkSupports: false) == .atStart, "feature off: loads at start, as shipped")
        #expect(loader.start([Self.folder], forkSupports: true) == .atStart, "feature off on a new fork")
        loader.featureOn = true
        #expect(loader.start([Self.folder], forkSupports: true) == .atFirstTab)
        #expect(loader.start([], forkSupports: false) == .atStart, "nothing to load: nothing to hold back")
    }

    /// `debug.cef` `built_in_extensions`: the feature, the fork's call, the person's choice and the way taken.
    @Test func theStartSaysWhichWayItWent() {
        let loader = CEFBuiltInExtensionLoader()
        loader.featureOn = true
        _ = loader.start([Self.folder], forkSupports: false)
        #expect(loader.lastStart == CEFBuiltInExtensionLoader.Start(placement: .off, feature: true, forkSupports: false,
                                                                     personChose: false, folders: 1))
    }

    private static func arguments(_ start: CEFBuiltInExtensionLoader.Start?) -> [String] {
        let inputs = (start ?? CEFBuiltInExtensionLoader.Start(placement: .atStart, feature: false, forkSupports: false,
                                                               personChose: false, folders: 1))
            .switchInputs(folders: [folder], keepsUnpackedEnabled: true)
        return CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: "com.cmuxterm.app.next", environment: [:],
                                   builtInExtensions: inputs.folders, builtInExtensionsAtFirstTab: inputs.atFirstTab,
                                   keepsUnpackedEnabled: inputs.keepsUnpackedEnabled).arguments
    }
}
