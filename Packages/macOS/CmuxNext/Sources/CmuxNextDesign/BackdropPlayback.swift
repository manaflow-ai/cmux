public import AppKit
import CCmuxWallpaperFFI
public import CmuxNextDesignTokens

/// Whether a video wallpaper (a file through ``BackdropVideoView``, a YouTube video through
/// ``BackdropYouTubeView``) plays now: the Rust scheduler's answer (`cmux_wallpaper_schedule`,
/// cmux-tui/crates/cmux-wallpaper/src/schedule.rs), the same one the live wallpapers ask, with the
/// seconds since any input as the activity, `appearance.videoWallpaperIdlePause` as the idle
/// time and no pointer interaction.
public nonisolated struct BackdropPlayback: Equatable, Sendable {
    /// What the view knows when it asks.
    public struct Terms: Equatable, Sendable {
        /// The window is on screen (not occluded).
        public var visible = true
        /// Other windows hide enough of it that it rests (``BackdropCoverage``).
        public var covered = false
        public var minimized = false
        public var appHidden = false
        public var screensAsleep = false
        public var sessionInactive = false
        public var lowPower = false
        /// Serious or critical thermal state.
        public var hot = false
        /// Looping motion is off (Reduce Motion, or the animation speed "off").
        public var reduceMotion = false
        /// Seconds since the last input anywhere in the session.
        public var secondsSinceInput: Double = 0
        /// Seconds without input before it pauses; infinity never.
        public var idleAfter: Double = .infinity
        /// One window at a time app-wide runs it (the YouTube embed), only at 200 pt a side or more.
        public var exclusive = false
        /// With `exclusive`: this window is the one chosen.
        public var chosen = true
        /// With `exclusive`: the player's viewport in points.
        public var size: CGSize = .zero

        public init() {}
    }

    /// The scheduler's hold reasons this side acts on (`CmuxWallpaperDecision.hold_reason`).
    public static let holdCovered: UInt8 = 2
    public static let holdIdle: UInt8 = 12
    public static let holdElsewhere: UInt8 = 13
    public static let holdTooSmall: UInt8 = 14
    /// It plays now.
    public let plays: Bool
    /// Why it holds, 0 while it plays.
    public let holdReason: UInt8

    /// The answer for `terms`.
    public init(_ terms: Terms) {
        var input = CmuxWallpaperScheduleInput()
        input.visible = terms.visible
        input.coverage_resting = terms.covered
        input.minimized = terms.minimized
        input.app_hidden = terms.appHidden
        input.screens_asleep = terms.screensAsleep
        input.session_inactive = terms.sessionInactive
        input.low_power = terms.lowPower
        input.thermal_serious = terms.hot
        input.reduce_motion = terms.reduceMotion
        input.animations_off = false
        input.seconds_since_activity = terms.secondsSinceInput
        input.seconds_since_pointer = .infinity
        input.interactive = false
        input.idle_after_s = terms.idleAfter
        input.exclusive = terms.exclusive
        input.chosen = terms.chosen
        input.width_pt = Float(terms.size.width)
        input.height_pt = Float(terms.size.height)
        input.manifest_fps = 30
        input.settings_fps_cap = 30
        input.scale = 1
        input.has_frame = true
        let answer = cmux_wallpaper_schedule(&input)
        plays = answer.run
        holdReason = answer.run ? 0 : answer.hold_reason
    }

    /// Someone could see it now: it plays, or it holds for a reason other than the window being
    /// out of sight (1-6: occluded, covered, minimized, hidden, screens asleep, session inactive).
    /// A video held for Low Power Mode, Reduce Motion, idle or another window keeps its frame.
    public var canBeSeen: Bool { plays || holdReason > 6 }

    /// It holds only for idle time: the next input plays it.
    public var idle: Bool { holdReason == Self.holdIdle }

    /// Every term but coverage and idle allows it: coverage is sampled only while this holds.
    public static func samplesCoverage(_ terms: Terms) -> Bool {
        var open = terms
        open.covered = false
        open.secondsSinceInput = 0
        let answer = BackdropPlayback(open)
        return answer.plays || answer.holdReason == holdElsewhere || answer.holdReason == holdTooSmall
    }

    /// The window terms of `window` now (visibility, minimized, the app hidden; the system's
    /// power, heat and motion), each replaced by a test's override.
    @MainActor public static func terms(_ window: NSWindow, visibleOverride: Bool?, lowPowerOverride: Bool?,
                                        reduceMotionOverride: Bool?, screensAsleep: Bool, sessionInactive: Bool) -> Terms {
        var terms = Terms()
        if let visibleOverride {
            terms.visible = visibleOverride
        } else {
            terms.visible = window.occlusionState.contains(.visible)
            terms.minimized = window.isMiniaturized
            terms.appHidden = NSApp.isHidden
        }
        terms.screensAsleep = screensAsleep
        terms.sessionInactive = sessionInactive
        terms.lowPower = lowPowerOverride ?? LowPowerMode.system.isEnabled
        terms.hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        terms.reduceMotion = reduceMotionOverride ?? !Motion.panes.animatesLoops
        return terms
    }
}
