@testable import CmuxNextBrowser
import Foundation
import Testing

/// Chrome backgrounds a renderer whose pages are all hidden (RenderProcessHostImpl::UpdateProcessPriority picks
/// kBestEffort; base/process/process_mac.cc applies TASK_BACKGROUND_APPLICATION with task suppression), and
/// Blink throttles hidden timers. Each switch below turns one of those off for every renderer
/// (content/public/common/content_switches.cc): automation browsers pass them (cmux-browser-host's CDP Chrome
/// does), but cmux's own Chromium must not, or no hidden page renderer ever backgrounds
/// (`bench-webui.py priority-roles`, p13-webui task 083, done check D12).
@Suite struct CEFRendererBackgroundingSwitchTests {
    static let keepRenderersForeground = [
        "disable-renderer-backgrounding",
        "disable-background-timer-throttling",
        "disable-backgrounding-occluded-windows",
    ]

    @Test(arguments: [Int32(0), 24, CEFSwitches.resizeSyncForkAPI, 29])
    func noRendererIsKeptAtForegroundPriority(forkAPI: Int32) {
        for rendererPaths in [false, true] {
            for bundle in ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"] {
                let arguments = CEFSwitches.current(forkAPIVersion: forkAPI, rendererPaths: rendererPaths,
                                                    bundleIdentifier: bundle, environment: [:],
                                                    keepsUnpackedEnabled: true).arguments
                let blockers = arguments.filter { argument in
                    Self.keepRenderersForeground.contains { argument == $0 || argument.hasPrefix($0 + "=") }
                }
                #expect(blockers.isEmpty, "fork API \(forkAPI), renderer paths \(rendererPaths), \(bundle): \(blockers)")
            }
        }
    }
}
