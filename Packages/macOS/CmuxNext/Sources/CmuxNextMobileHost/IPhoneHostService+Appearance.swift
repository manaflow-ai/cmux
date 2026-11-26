import AppKit
import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextMobile
import Foundation
import os

/// This Mac's theme and wallpaper reach the iPhone (ask-87d30da8e5): the colors the chrome derives
/// from (the terminal theme, or `appearance.appTheme`, with `appearance.accent`) and the picture
/// the windows show, as a phone-sized JPEG. Each change goes whole to `cmux-mobile-host`, which
/// keeps every rule and serves it (`appearance.rs`); the phone derives its chrome from the same
/// colors with the same code (`ThemeTokens.derive`), so it computes them offline too.
///
/// Stop condition: the task ends when `IPhoneHostService.stop` cancels it (`followingAppearance`).
@MainActor
enum ThemePhone {
    /// One line per appearance handed to hostd, so a run times each hop of a theme change
    /// (scripts/ci/cmux_next_pair_e2e.py's theme-file leg reads it from the pairing log).
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.iphone.appearance")

    /// What the phone gets, read on the main actor: the source picture, not yet the phone copy.
    struct Shown: Equatable, Sendable {
        var appearance: MobileHostAppearance
        /// What the windows show behind their content, in the theme's light or dark frame.
        var wallpaper: Wallpaper?
        var dark: Bool
        /// The desktop watch's ``DesktopWallpaperWatch/revision`` while the wallpaper is the
        /// desktop (0 otherwise), so a new desktop picture is a new state.
        var desktop = 0
    }

    /// Where the phone's wallpaper comes from: what this Mac shows behind its windows' content.
    enum WallpaperSource: Equatable, Sendable {
        /// A picture file: the background chosen in cmux, or the Ghostty config's `background-image`.
        case file(URL)
        /// The desktop picture of the screen the windows are on (the main screen's,
        /// ``DesktopWallpaperWatch``), which a see-through window shows.
        case desktop
    }

    /// The phone's wallpaper before its phone copy: where it comes from and the tint over it.
    struct Wallpaper: Equatable, Sendable {
        var source: WallpaperSource
        /// The alpha of the theme's background the phone lays over the picture, 0...1.
        var tint: Double
    }

    /// What this Mac shows behind its windows' content, for the phone (ask-87d30da8e5).
    /// The first that holds:
    /// 1. A background chosen in cmux (`selected`): its picture (`selectedPicture`; one without a
    ///    still, as a living shader, sends none) at the tint the windows lay over it (`selectedTint`).
    ///    Desktop Wallpaper (`selectedDesktop`) is the desktop, which the watch reads off the main
    ///    thread and follows as macOS rotates it.
    /// 2. The Ghostty config's `background-image` (`terminalImage`): that picture. Ghostty draws an
    ///    opaque pixel of it at `terminalImage.opacity` over the window's background, so the phone's
    ///    tint is the rest, `1 - opacity`. In a see-through window part of that rest is the desktop
    ///    under the window's tint; the phone has no desktop and draws all of it as the background.
    /// 3. A see-through window (`windowSeeThrough`): the desktop picture under the window's tint
    ///    sheet (`windowTint`, ``WindowBackdrop/tintOpacity``: the resolved `background-opacity`).
    /// 4. An opaque window with no picture: none.
    static func wallpaper(selected: Bool, selectedDesktop: Bool = false, selectedPicture: URL?, selectedTint: Double,
                          terminalImage: TerminalBackgroundImage?, windowSeeThrough: Bool,
                          windowTint: Double) -> Wallpaper? {
        if selectedDesktop { return Wallpaper(source: .desktop, tint: selectedTint) }
        if selected { return selectedPicture.map { Wallpaper(source: .file($0), tint: selectedTint) } }
        if let terminalImage { return Wallpaper(source: .file(terminalImage.url), tint: 1 - terminalImage.opacity) }
        if windowSeeThrough { return Wallpaper(source: .desktop, tint: min(max(windowTint, 0), 1)) }
        return nil
    }

    /// The window's material in Ghostty's `background-blur` C encoding, as `backdrop` resolved it:
    /// -2 clear Liquid Glass, -1 regular, the frost radius when frosted, 0 for none (opaque, or
    /// plain see-through). Glass this Mac cannot draw is already its frost radius in `backdrop`.
    static func blur(_ backdrop: WindowBackdrop) -> Int {
        switch backdrop.material {
        case .glass(.clear): -2
        case .glass(.regular): -1
        case .frosted: backdrop.windowBlurRadius
        case .opaque, .translucent: 0
        }
    }

    /// `#rrggbb` of an opaque color.
    static func hex(_ color: ThemeRGB) -> String {
        String(format: "#%02x%02x%02x", Int((min(max(color.red, 0), 1) * 255).rounded()),
               Int((min(max(color.green, 0), 1) * 255).rounded()), Int((min(max(color.blue, 0), 1) * 255).rounded()))
    }

    /// The appearance of `input` and `tokens` (the app store's), with the tint the windows lay
    /// over a picture. Under Art Color the accent the windows show is sent as the theme's own.
    /// `terminal`: the Ghostty config's terminal theme lines (``ThemeStore/terminalConfigLines``),
    /// which the phone's terminals load whatever the chrome shows.
    static func appearance(input: ThemeInput, tokens: ThemeTokens, accentFollowsArt: Bool, tint: Double,
                           terminal: [String] = []) -> MobileHostAppearance {
        MobileHostAppearance(
            background: hex(input.background), foreground: hex(input.foreground), palette: input.palette.map(hex),
            selectionBackground: input.selectionBackground.map(hex), selectionForeground: input.selectionForeground.map(hex),
            cursor: input.cursor.map(hex), accent: accentFollowsArt ? "art" : input.accent.rawValue,
            accentColor: accentFollowsArt ? hex(tokens.accent) : input.accentColor.map(hex),
            backgroundOpacity: input.backgroundOpacity, wallpaperTintOpacity: tint, terminal: terminal)
    }

    /// The look beyond the colors as the windows show it: the scope's tuning (hue, saturation,
    /// glass), the window style and sidebar surface, the terminals' font, the Home chat bubble
    /// colors and the sidebar's group colors. hostd checks every field (`appearance.rs`).
    static func look(tuning: AppearanceTuning, design: DesignSettings) -> MobileHostAppearance.Look {
        MobileHostAppearance.Look(
            chromeStyle: design.chromeStyle.rawValue, hue: tuning.hue, saturation: tuning.saturation,
            glassTransparency: tuning.glassTransparency, sidebarSurface: design.sidebarSurface.rawValue,
            terminalFontFamily: design.effectiveTerminalFontFamily, terminalFontSize: design.terminalFontSize,
            chatColors: design.homeBubbleColors, groupPalette: design.sidebarSections.groupPalette.rawValue,
            groupGradient: design.sidebarSections.groupGradient.rawValue)
    }

    /// What the app's scope shows now (observed: the store's colors, its picture's revision, the
    /// Ghostty `background-image`, and while the window shows the desktop, the desktop's revision).
    static func shown(_ scope: ThemeScope) -> Shown {
        let store = scope.store
        _ = store.backdropRevision.value
        let tokens = store.tokens
        let selection = scope.backdropSelection
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // The window as it draws: over the chosen picture, else over the desktop.
        let backdrop = WindowBackdrop(tokens, reduceTransparency: reduceTransparency, art: scope.backdropArt,
                                      selection: selection, tuning: scope.appearanceTuning,
                                      tintOpacity: scope.backdropTintOpacity)
        let selectedTint = scope.backdropTintOpacity ?? tokens.wallpaperTintOpacity
        let selectedDesktop = selection?.resolved(dark: tokens.isDark) == .desktop
        let wallpaper = wallpaper(selected: selection != nil, selectedDesktop: selectedDesktop,
                                  selectedPicture: selectedDesktop ? nil : selection.flatMap { $0.resolvedImageURL(dark: tokens.isDark) },
                                  selectedTint: selectedTint, terminalImage: store.terminalBackgroundImage,
                                  windowSeeThrough: !backdrop.isOpaque, windowTint: backdrop.tintOpacity)
        var appearance = appearance(input: store.input, tokens: tokens, accentFollowsArt: store.accentFollowsArt,
                                    tint: wallpaper?.tint ?? selectedTint, terminal: store.terminalConfigLines)
        appearance.backgroundBlur = blur(backdrop)
        appearance.look = look(tuning: scope.appearanceTuning, design: DesignSettings.shared)
        let desktop = wallpaper?.source == .desktop ? BackdropImageStore.shared.desktop.revision.value : 0
        return Shown(appearance: appearance, wallpaper: wallpaper, dark: tokens.isDark, desktop: desktop)
    }

    /// Where the phone copies of the pictures go.
    static var folder: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux-next", isDirectory: true)
            .appendingPathComponent("phone-wallpaper", isDirectory: true)
    }

    /// Whether a phone can get the appearance: iPhone connections are on and one is paired. Until
    /// then nothing is decoded or written; the follow wakes when either changes.
    static func wanted(_ iphone: IPhoneHostService) -> Bool {
        iphone.allowed && !(iphone.paired?.devices.isEmpty ?? true)
    }

    /// Follows the app's theme and picture and hands each new state to the iPhone host, while a
    /// phone can get it (``wanted(_:)``).
    static func follow(scope: ThemeScope, iphone: IPhoneHostService) -> Task<Void, Never> {
        let folder = folder
        // task-owner: IPhoneHostService.followingAppearance; event-driven (Observation), cancelled by stop().
        return Task { [weak iphone] in
            let states = ObservationStream { [weak iphone] () -> Shown? in
                guard let iphone, wanted(iphone) else { return nil }
                return shown(scope)
            }
            for await next in states {
                guard let shown = next else { continue }
                var appearance = shown.appearance
                if let source = shown.wallpaper?.source {
                    let dark = shown.dark
                    // The desktop as the app's watch last read it (off the main thread); until its
                    // first reading lands there is none, and that reading sends it.
                    let desktop = source == .desktop ? BackdropImageStore.shared.desktop.picture : nil
                    // Resolving and decoding a picture never runs on the main actor.
                    appearance.wallpaper = await Task.detached(priority: .utility) { () -> URL? in
                        let picture: URL? = switch source {
                        case .file(let url): url
                        case .desktop: desktop?.resolvedURL(dark: dark)
                        }
                        return picture.flatMap { BackdropImageStore.phoneCopy(of: $0, dark: dark, in: folder) }
                    }.value
                }
                guard !Task.isCancelled, let iphone else { return }
                let terminalBackground = appearance.terminal.last { $0.hasPrefix("background = ") }
                    .map { String($0.dropFirst("background = ".count)) } ?? "none"
                logger.info("appearance to hostd: background \(appearance.background, privacy: .public), terminal background \(terminalBackground, privacy: .public)")
                await iphone.setAppearance(appearance)
            }
        }
    }
}

extension IPhoneHostService {
    /// Hands this Mac's theme and wallpaper, as `scope` shows them, to hostd from now on
    /// (ask-87d30da8e5). `init(appearance:)` calls it with the app's scope.
    func followAppearance(of scope: ThemeScope) {
        followingAppearance?.cancel()
        followingAppearance = ThemePhone.follow(scope: scope, iphone: self)
    }
}
