import CmuxNextCompat
import Foundation
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups
import Observation

/// cmux's own terminal look in cmux.json, written by onboarding:
/// `appearance.theme` (a Ghostty theme, or `light:A,dark:B`) and
/// `terminal.fontFamily` / `terminal.fontSize`, plus the window background
/// (`appearance.backgroundOpacity`, `appearance.backgroundBlur`). Applied
/// as Ghostty overrides (`GhosttyRuntime.themeOverride`, `fontOverride`,
/// `backgroundOverride`) and a config reload, so terminals and chrome
/// follow live. The Ghostty config file itself never changes.
/// `ui.reducedBackgrounds` overrides the window background and hides the
/// pictures here, the one place both are applied.
@MainActor
final class TerminalThemeSetting {
    static let path = AppThemeSetting().configPath
    static let fontSizePath = TerminalFontSetting().sizePath

    private struct State: Equatable {
        var theme: String?
        var edits = ThemeEdits.none
        var font: GhosttyRuntime.FontOverride
        var background: WindowBackgroundOverride
        /// `appearance.surfaces.terminal` is set: surfaces draw a
        /// transparent default background (`GhosttyRuntimeSurfacePolicy`).
        var terminalOverridden = false

        init(theme: String?, font: GhosttyRuntime.FontOverride, background: WindowBackgroundOverride, terminalOverridden: Bool = false) {
            (self.theme, self.font, self.background, self.terminalOverridden) = (theme, font, background, terminalOverridden)
        }

        /// Parsed and validated in `CmuxConfigSnapshot` (a bad value is a
        /// diagnostic and keeps the Ghostty config's).
        init(_ snapshot: CmuxConfigSnapshot) {
            self.init(theme: snapshot.appTheme,
                      font: GhosttyRuntime.FontOverride(family: snapshot.terminalFontFamily, size: snapshot.terminalFontSize),
                      background: ReducedBackgroundsSetting.drawn(snapshot.windowBackground, reduced: snapshot.reducedBackgrounds),
                      terminalOverridden: snapshot.surfaceBackgrounds.overridesTerminal)
            edits = snapshot.themeEdits
            edits.highlight = snapshot.highlightColor
        }
    }

    /// What the runtime's first config load had (`prime`); taken by the
    /// first apply, which skips the reload when it matches.
    private static var primed: State?

    private let backdropScope: ThemeScope

    init(backdropScope: ThemeScope) {
        self.backdropScope = backdropScope
    }

    private var applied: State?
    /// Reloads the Ghostty config with the overrides (tests count it).
    var reload: () -> Void = { GhosttyRuntime.shared.reloadConfig() }
    /// Repaints the window from the theme with the new background, before the reload.
    lazy var repaint: () -> Void = { [backdropScope] in ThemeBridge.repaintBackground(store: backdropScope.store) }
    /// The reload after the last step of a window background drag (the Opacity slider).
    private let reloadTimer = DemandTimer(owner: "terminal-theme.background-reload")
    /// How long that reload waits after a step (tests lengthen it, so a slow host's steps still coalesce).
    var reloadDelay = TerminalThemeSetting.backgroundReloadDelay
    /// Shuffle: turns the backdrop to its next picture when the period ends (``BackdropRotation``).
    private let dailyTimer = DemandTimer(owner: "terminal-theme.daily-background")
    /// The clock and calendar (read per pick, so a time zone change applies) a shuffle reads; tests pin both.
    var now: () -> Date = Date.init, calendar: () -> Calendar = { .current }
    /// Where it hears of a day, time zone or clock change (tests post to their own); set before `follow`.
    var notificationCenter: NotificationCenter = .default
    /// The shuffle the background is, so a day, time zone or clock change re-picks its picture.
    private var shuffling: BackdropShuffle?
    private var dayObservers: [any NSObjectProtocol] = []
    static let backgroundReloadDelay = Duration.milliseconds(60)
    private var observation: Task<Void, Never>?

    /// Applies the loaded settings at once (launch loads them before the
    /// first window, which must not draw a frame in the defaults), then
    /// follows their changes.
    func follow(_ settings: SettingsController) {
        // An opacity write with Material unset names the material of the config files' own blur.
        settings.ghosttyBackgroundBlur = { GhosttyConfigBackground.loaded.blur }
        // The theme, its edits, the window background, the backdrop art and the tuning follow
        // `applied`, so a theme picker's, the Opacity, Hue or Saturation slider's or the background
        // picker's live preview repaints the window; the rest follows the loaded
        // settings, so a font size slider's preview never reloads Ghostty per tick. A background step
        // repaints at once and reloads Ghostty after the steps stop (`apply`).
        take(settings.snapshot, theme: settings.applied.appTheme, edits: settings.applied.themeEdits,
             background: settings.applied.windowBackground, art: settings.applied.backdropSelection,
             shuffle: BackdropSelectionSetting.shuffle(settings.applied.root), tuning: settings.applied.windowTuning,
             reduced: settings.applied.reducedBackgrounds)
        // A time zone or clock change moves local midnight, which the armed timer cannot see.
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            dayObservers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.shuffling != nil else { return }
                    self.showShuffledArt()
                }
            })
        }
        observation = Task { [weak self] in
            for await (snapshot, theme, edits, background, art, shuffle, tuning, reduced) in ObservationStream({
                (settings.snapshot, settings.applied.appTheme, settings.applied.themeEdits, settings.applied.windowBackground,
                 settings.applied.backdropSelection, BackdropSelectionSetting.shuffle(settings.applied.root), settings.applied.windowTuning,
                 settings.applied.reducedBackgrounds)
            }) {
                self?.take(snapshot, theme: theme, edits: edits, background: background, art: art, shuffle: shuffle, tuning: tuning,
                           reduced: reduced)
            }
        }
    }

    private func take(_ snapshot: CmuxConfigSnapshot, theme: String?, edits: ThemeEdits, background: WindowBackgroundOverride,
                      art: BackdropSelection?, shuffle: BackdropShuffle?, tuning: AppearanceTuning, reduced: Bool) {
        shuffling = shuffle
        // `reduced` (`ui.reducedBackgrounds`, from `applied` so a preview of it repaints): the plain
        // theme background; the person's picks are kept.
        backdropScope.setBackdropsHidden(reduced)
        if shuffle != nil {
            showShuffledArt()
        } else {
            dailyTimer.cancel()
            backdropScope.setBackdropSelection(art)
        }
        backdropScope.setAppearanceTuning(tuning)
        // Per-surface backgrounds (R55): every owner repaints from them.
        backdropScope.setSurfaceBackgrounds(snapshot.surfaceBackgrounds)
        // Over a picture the Opacity the user set is the window's tint (unset: the work's own).
        backdropScope.setWindowBackdropTint(reduced ? nil : background.opacity)
        var state = State(snapshot)
        state.theme = theme
        state.edits = edits
        state.edits.highlight = snapshot.highlightColor
        state.background = ReducedBackgroundsSetting.drawn(background, reduced: reduced)
        apply(state)
    }

    /// Shows the shuffle's picture of `now()` and turns to the next one when its period ends.
    func showShuffledArt() {
        guard let turn = shuffling?.turn(at: now(), calendar: calendar()) else { return }
        backdropScope.setBackdropSelection(turn.picture)
        dailyTimer.schedule(after: .seconds(turn.wait)) { @MainActor [weak self] in self?.showShuffledArt() }
    }

    /// Puts `snapshot`'s appearance on the Ghostty overrides before the
    /// runtime starts, so its first config load already has them.
    static func prime(_ snapshot: CmuxConfigSnapshot) {
        let state = State(snapshot)
        primed = state
        set(state)
    }

    /// The review tool's light/dark preview: Ghostty's Apple System Colors
    /// (dark) or Apple System Colors Light, in memory only (nil: back to the
    /// configured theme). Never writes cmux.json.
    func preview(dark: Bool?) {
        GhosttyRuntime.themeOverride = dark.map { $0 ? GhosttyRuntime.defaultDarkThemeName : GhosttyRuntime.defaultLightThemeName } ?? applied?.theme
        GhosttyRuntime.shared.reloadConfig()
    }

    private func apply(_ state: State) {
        guard applied != state else { return }
        let previous = applied
        applied = state
        Self.set(state)
        if let previous {
            var others = state
            others.background = previous.background
            guard others == previous, !Self.changesSurfaces(from: previous.background, to: state.background) else {
                reloadTimer.cancel()
                return reload()
            }
            // Only the opacity or a frosted radius moved: the window repaints now, and Ghostty
            // reloads once after the last step instead of on every one.
            repaint()
            return reloadTimer.schedule(after: reloadDelay) { @MainActor [weak self] in self?.reload() }
        }
        // At launch the config already loaded with these overrides (primed) or none.
        let loaded = Self.primed ?? State(theme: nil, font: .init(), background: .init())
        Self.primed = nil
        if state != loaded { reload() }
    }

    /// Whether the terminals need the reload at once: the window turns translucent or opaque (the
    /// surfaces' default background changes) or its material changes.
    static func changesSurfaces(from old: WindowBackgroundOverride, to new: WindowBackgroundOverride) -> Bool {
        let (opacity, blur) = (GhosttyConfigBackground.loaded.opacity, GhosttyConfigBackground.loaded.blur)
        let before = old.resolved(backgroundOpacity: opacity, backgroundBlur: blur)
        let after = new.resolved(backgroundOpacity: opacity, backgroundBlur: blur)
        return (before.backgroundOpacity >= 1) != (after.backgroundOpacity >= 1)
            || WindowMaterialChoice(ghosttyBlur: before.backgroundBlur) != WindowMaterialChoice(ghosttyBlur: after.backgroundBlur)
    }

    private static func set(_ state: State) {
        GhosttyRuntime.themeOverride = state.theme
        GhosttyRuntime.themeEdits = state.edits
        GhosttyRuntime.fontOverride = state.font
        let family = state.font.family?.trimmingCharacters(in: .whitespaces) ?? ""
        DesignSettings.shared.terminalFontFamily = family.isEmpty ? nil : family
        GhosttyRuntime.backgroundOverride = state.background
        GhosttyRuntime.terminalBackgroundOverridden = state.terminalOverridden
    }
}
