import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// The settings-selected channel flows through the driver seam: the feed the driver reports
/// follows the provider on every resolution (no relaunch), and the manual-download recovery
/// routes a setting-selected RC feed to the RC DMG.
@Suite @MainActor struct UpdateChannelSelectionTests {
    private final class ChannelBox {
        var selection: UpdateChannelSelection = .stable
    }

    private func makeDriver(box: ChannelBox, infoFeedURL: String?) -> UpdateDriver {
        UpdateDriver(
            model: UpdateStateModel(),
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false,
            infoFeedURLProvider: { infoFeedURL },
            selectedChannelProvider: { box.selection },
            feedResolver: UpdateFeedResolver(hostArchitecture: .arm64)
        )
    }

    @Test func driverFollowsTheSelectionWithoutRelaunch() {
        let box = ChannelBox()
        let driver = makeDriver(box: box, infoFeedURL: "https://cmux.com/appcast.xml")
        #expect(driver.resolvedFeedURLString() == "https://cmux.com/appcast.xml")

        box.selection = .rc
        #expect(driver.resolveFeed().url == "https://files.cmux.com/rc/appcast-arm64.xml")
        #expect(driver.resolvedFeedURLString() == "https://files.cmux.com/rc/appcast-arm64.xml")

        box.selection = .stable
        #expect(driver.resolvedFeedURLString() == "https://cmux.com/appcast.xml")
    }

    @Test func nightlyDriverIgnoresTheSelection() {
        let box = ChannelBox()
        box.selection = .rc
        let driver = makeDriver(box: box, infoFeedURL: "https://files.cmux.com/nightly/appcast.xml")
        #expect(driver.resolvedFeedURLString() == "https://files.cmux.com/nightly/appcast-arm64.xml")
    }

    /// A stable install that switched to RC in settings recovers to the RC DMG, not the stable
    /// one, because the feed in effect at failure time is the RC feed.
    @Test func recoveryRoutesASettingSelectedRCFeedToTheRCDMG() throws {
        let box = ChannelBox()
        box.selection = .rc
        let driver = makeDriver(box: box, infoFeedURL: "https://cmux.com/appcast.xml")
        let didNotStart = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode)
        let recovery = UpdateManualDownloadRecovery(hostArchitecture: .arm64)

        let rcURL = try #require(recovery.url(for: didNotStart, feedURLString: driver.resolvedFeedURLString()))
        #expect(rcURL.absoluteString == "https://github.com/manaflow-ai/cmux/releases/download/rc/cmux-rc-macos-arm64.dmg")

        box.selection = .stable
        let stableURL = try #require(recovery.url(for: didNotStart, feedURLString: driver.resolvedFeedURLString()))
        #expect(stableURL.absoluteString == "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg")
    }
}
