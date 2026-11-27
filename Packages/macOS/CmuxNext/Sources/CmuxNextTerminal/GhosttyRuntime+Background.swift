public import CmuxNextDesign
import Foundation
import GhosttyNextKit

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
        DispatchQueue.main.async {
            seeThroughReloadPending = false
            if seeThroughShown != seeThroughLoaded { shared.reloadConfig() }
        }
    }

    /// The config's `background-image` as the surfaces draw it, for the iPhone's wallpaper
    /// (ask-87d30da8e5); nil without one or without a config. Its opacity is what an opaque pixel
    /// of the picture shows at: the applied `background-image-opacity` times the applied
    /// `background-opacity`, as Ghostty draws it. That product is the user's own
    /// `background-image-opacity * background-opacity` whether or not the surface policy raised
    /// the image's opacity over a carrier background (`GhosttyRuntimeSurfacePolicy`).
    public var backgroundImage: TerminalBackgroundImage? {
        guard let config else { return nil }
        return Self.backgroundImage(of: config)
    }

    static func backgroundImage(of config: ghostty_config_t) -> TerminalBackgroundImage? {
        var path = ghostty_config_path_s()
        guard configGet(config, &path, key: "background-image"), let raw = path.path.map({ String(cString: $0) }),
              !raw.isEmpty else { return nil }
        var imageOpacity: Float = 1
        _ = configGet(config, &imageOpacity, key: "background-image-opacity")
        var opacity: Double = 1
        _ = configGet(config, &opacity, key: "background-opacity")
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        return TerminalBackgroundImage(url: url, opacity: Double(imageOpacity) * min(max(opacity, 0), 1))
    }

    /// The ``seeThroughShown`` the loaded config's surface policy read.
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
