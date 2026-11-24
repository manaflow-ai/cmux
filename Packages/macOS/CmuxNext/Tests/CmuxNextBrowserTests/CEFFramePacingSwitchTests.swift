@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// Chromium presents a page's frame as soon as it has drawn it, instead of waiting for the next display refresh
/// (`CEFFramePacing`, Debug Settings > Browser Page Loading). A key typed into a streaming agent chat waited 5.2 ms
/// p50 at 120 Hz and 12.6 ms at 60 Hz for the next BeginFrame (hq#15723; Leo, 2026-11-20: "why do we ever even wait
/// for screen frames? we shouldnt bother most of the time i think"), and this is the arm that takes that wait off.
///
/// It is off by default because it also lets an animating page draw frames the display never shows, and it is a
/// launch-time switch: Chromium reads its command line once, so an arm is decided when the process starts.
@MainActor @Suite(.serialized) struct CEFFramePacingSwitchTests {
    private func defaultSwitches(noFrameRateLimit: Bool = false) -> CEFSwitches {
        CEFSwitches(forkAPIVersion: 35, useMockKeychain: false, loadExtensions: [], noFrameRateLimit: noFrameRateLimit)
    }

    /// Both switches or neither: `disable-gpu-vsync` stops the display from gating the compositor's BeginFrames and
    /// `disable-frame-rate-limit` stops Chromium's own cap from replacing it, so one alone leaves the frame rate
    /// pegged to the refresh and would measure as the off arm.
    @Test func theTwoSwitchesGoTogether() {
        #expect(CEFFramePacing.switches == ["disable-gpu-vsync", "disable-frame-rate-limit"])
        let on = defaultSwitches(noFrameRateLimit: true).arguments
        for name in CEFFramePacing.switches { #expect(on.contains(name), "\(name) is missing from \(on)") }
    }

    @Test func aPageWaitsForTheDisplayByDefault() {
        #expect(CEFFramePacing.noFrameRateLimit.defaultValue == false)
        #expect(BrowserPageTunables.all.contains { $0.key == "browserPage.noFrameRateLimit" },
                "the toggle is not in Debug Settings > Browser Page Loading")
        let off = defaultSwitches().arguments
        for name in CEFFramePacing.switches { #expect(!off.contains(name), "\(name) is passed with the setting off: \(off)") }
    }

    /// The launch path carries the setting's value into the switches it passes Chromium, in every build the store is
    /// active in: an arm that stored the toggle and launched without the switches is the labelling trap cmux#45709
    /// shipped, and the typing bench's `launch_switch` row reads this path.
    @Test(arguments: [true, false])
    func theLaunchSwitchesFollowTheStoredSetting(on: Bool) {
        let key = CEFFramePacing.noFrameRateLimit.key
        TunableStore.shared.register(BrowserPageTunables.all)
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.set(key, .bool(on))
        defer { TunableStore.shared.set(key, nil) }
        let switches = CEFSwitches.current(forkAPIVersion: 35, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(switches.noFrameRateLimit == on)
        for name in CEFFramePacing.switches {
            #expect(switches.arguments.contains(name) == on, "\(name) with the setting \(on ? "on" : "off"): \(switches.arguments)")
        }
    }
}
