import Foundation
import Testing
@testable import CmuxNextBrowser

/// p14-energy-109: Q8 turns Chromium's idle sources off one location at a time, but Safe Browsing and
/// the CRLSet stay. No configuration of the browser process passes a switch that stops their updates
/// (`disable-component-update` skips the CRLSet component's registration).
@Suite struct CEFSecurityUpdateSwitchTests {
    @Test(arguments: [Int32(0), 27, 29, CEFSwitches.pageSiteSharingForkAPI])
    func noConfigurationStopsSecurityUpdates(forkAPIVersion: Int32) {
        let switches = CEFSwitches.current(
            forkAPIVersion: forkAPIVersion,
            rendererPaths: true,
            chromiumFeatures: ["TimerSlackMac"],
            spareAfterFirstTab: true,
            bundleIdentifier: "com.cmuxterm.app.next",
            environment: ["CMUX_NEXT_CEF_LOAD_EXTENSIONS": "/tmp/extension"],
            builtInExtensions: ["/tmp/ublock"],
            keepsUnpackedEnabled: true,
            agentPageMainFrameCap: 8,
            pageSiteCaps: [CEFSwitches.PageSiteCap(site: CEFSwitches.agentPageSite, mainFrames: 8)]
        )
        let names = switches.arguments.map { argument in
            String(argument.prefix { $0 != "=" })
        }
        #expect(CEFSwitches.securityUpdateSwitches.isDisjoint(with: names), "\(switches.arguments)")
    }

    @Test func theListHasChromiumsComponentUpdateSwitch() {
        #expect(CEFSwitches.securityUpdateSwitches.contains("disable-component-update"))
    }
}
