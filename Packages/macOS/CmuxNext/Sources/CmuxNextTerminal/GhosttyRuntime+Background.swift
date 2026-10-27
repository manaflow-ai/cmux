public import CmuxNextDesign
import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// cmux's own window background (`appearance.backgroundOpacity`,
/// `appearance.backgroundBlur` in cmux.json), loaded after the Ghostty
/// config files like `fontOverride`, so the opacity the surfaces, the
/// window and the theme read is the resolved one. Set, then call
/// `reloadConfig()`.
extension GhosttyRuntime {
    /// cmux.json's window background, laid over the config files' opacity
    /// and blur on every config load. Empty (the default) keeps them.
    public static var backgroundOverride = WindowBackgroundOverride()

    /// Whether cmux.json overrides the terminal's background
    /// (`appearance.surfaces.terminal`): the surfaces then draw a
    /// transparent default background in every window and the terminal
    /// host paints the override (`GhosttyRuntimeSurfacePolicy`). Set, then
    /// call `reloadConfig()`.
    public static var terminalBackgroundOverridden = false

    /// The terminal hosts the window is see-through around (`TerminalHostView.paintBackground`).
    /// Over art a window is see-through at any opacity (`WindowBackdrop`): while some host is, the
    /// surfaces draw a transparent default background and the hosts paint what the panes paint
    /// there (`GhosttyRuntimeSurfacePolicy`).
    private static let seeThroughHosts = NSHashTable<AnyObject>.weakObjects()

    /// Whether some terminal sits in a see-through window.
    static var seeThroughShown: Bool { !seeThroughHosts.allObjects.isEmpty }

    /// Records whether the window is see-through around `host`, and reloads the config when that
    /// turns ``seeThroughShown`` on or off.
    static func setSeeThrough(_ seeThrough: Bool, host: AnyObject) {
        if seeThrough { seeThroughHosts.add(host) } else { seeThroughHosts.remove(host) }
        guard seeThroughShown != seeThroughLoaded, !seeThroughReloadPending else { return }
        // Not inside the theme pass that asked: the reload repaints the hosts again. One reload
        // per turn, and none when the set flipped back (a host moving between superviews).
        seeThroughReloadPending = true
        let reload: @MainActor () -> Void = {
            seeThroughReloadPending = false
            if seeThroughShown != seeThroughLoaded { shared.reloadConfig() }
        }
        // A window's look changed on screen: visible work, after the pass that asked.
        guard let mainWork = shared.mainWork else { return MainRunLoopBlock.perform(reload) }
        mainWork.post(.visible, owner: "ghostty.seeThrough", reload)
    }

    /// The ``seeThroughShown`` the last config build asked for reads (set when asked: `GhosttyConfigInputs.current`).
    static var seeThroughLoaded = false
    private static var seeThroughReloadPending = false

    /// Config lines that turn the config's `background-opacity` and
    /// `background-blur` into what `background` resolves them to; empty
    /// when nothing changes.
    ///
    /// - Parameter background: The cmux.json override.
    /// - Parameter configuredOpacity: The config's `background-opacity`.
    /// - Parameter configuredBlur: The config's `background-blur`, in
    ///   Ghostty's C encoding.
    /// - Returns: Lines for `ghostty_config_load_string`.
    public nonisolated static func backgroundOverrideLines(_ background: WindowBackgroundOverride,
                                                           configuredOpacity: Double, configuredBlur: Int) -> [String] {
        let resolved = background.resolved(backgroundOpacity: configuredOpacity, backgroundBlur: configuredBlur)
        var lines: [String] = []
        if resolved.backgroundOpacity != configuredOpacity {
            lines.append("background-opacity = \(resolved.backgroundOpacity)")
        }
        if resolved.backgroundBlur != configuredBlur {
            switch resolved.backgroundBlur {
            case -1: lines.append("background-blur = macos-glass-regular")
            case -2: lines.append("background-blur = macos-glass-clear")
            case let radius: lines.append("background-blur = \(max(radius, 0))")
            }
        }
        return lines
    }
}
