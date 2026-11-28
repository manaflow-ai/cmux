import CmuxNextDesign
import Foundation

/// Chromium's browser pages draw a frame when they have one, not when the display asks
/// (`--disable-gpu-vsync`, `--disable-frame-rate-limit`).
///
/// A key's change reaches the screen a frame period late because the page waits for the next
/// BeginFrame to start its frame: measured on the typing bench, a key typed into a streaming agent
/// chat waited 5.2 ms p50 at 120 Hz and 12.6 ms at 60 Hz for that frame to start, scaling with the
/// period the way a vsync wait does (hq#15723). Leo, 2026-11-20: "why do we ever even wait for
/// screen frames? we shouldnt bother most of the time i think".
///
/// These two switches take the frame rate limit off Chromium's compositor, so a page presents as
/// soon as it has drawn. **It is a cost as well as a win**: an animating or streaming page then
/// draws as fast as it can rather than once per refresh, which burns GPU and CPU for frames no one
/// sees, and tearing becomes possible. So this is off by default and measured first (the bench's
/// `--ab browserPage.noFrameRateLimit` arm records the app's and WindowServer's CPU beside the key
/// latencies). What the numbers are for is deciding whether the right shape is this, or drawing at
/// once only on input and pacing by frame for animation (`CEFDrawOnInput`, fork API 35).
///
/// Launch-time, because Chromium reads its command line once: a bench A/B drives it through the
/// build's own `debug-tunables.json`, one launch per arm, not the live `debug.tunables` RPC.
nonisolated enum CEFFramePacing {
    /// Debug Settings > Browser Page Loading. Off by default: it trades frames nobody sees for
    /// latency, and no number yet says that trade is right (hq#15723).
    static let noFrameRateLimit = Tunable<Bool>.toggle(
        "browserPage.noFrameRateLimit", BrowserPageTunables.section, "Draw pages without waiting for the display",
        help: "Chromium presents a browser page's frame as soon as it has drawn it, instead of waiting for the next display refresh (up to 16.7 ms at 60 Hz). Cuts typing and scrolling latency on a page, and lets an animating page draw more frames than the display shows, which costs GPU and CPU. Takes effect at the next launch.",
        default: false, code: "CEFFramePacing.noFrameRateLimit")

    /// The switches the setting adds. `disable-gpu-vsync` stops the display from gating the
    /// compositor's BeginFrames; `disable-frame-rate-limit` stops Chromium's own cap from replacing
    /// it (one without the other leaves the frame rate pegged to the refresh).
    ///
    /// A constant, not a read of the tunable: the launch path reads the setting once
    /// (`CEFSwitches.current`, through `settledValue`) and carries the flag, so these cannot
    /// disagree with the value that process launched with.
    static let switches = ["disable-gpu-vsync", "disable-frame-rate-limit"]
}
