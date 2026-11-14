import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextMobile
import Foundation

/// This Mac's theme and wallpaper reach the iPhone (ask-87d30da8e5): the colors the chrome derives
/// from (the terminal theme, or `appearance.appTheme`, with `appearance.accent`) and the picture
/// the windows show, as a phone-sized JPEG. Each change goes whole to `cmux-mobile-host`, which
/// keeps every rule and serves it (`appearance.rs`); the phone derives its chrome from the same
/// colors with the same code (`ThemeTokens.derive`), so it computes them offline too.
///
/// Stop condition: the task ends when `IPhoneHostService.stop` cancels it (`followingAppearance`).
@MainActor
enum ThemePhone {
    /// What the phone gets, read on the main actor: the source picture, not yet the phone copy.
    struct Shown: Equatable, Sendable {
        var appearance: MobileHostAppearance
        /// The picture the windows show, in the theme's light or dark frame.
        var picture: URL?
        var dark: Bool
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

    /// What the app's scope shows now (observed: the store's colors and its picture's revision).
    static func shown(_ scope: ThemeScope) -> Shown {
        let store = scope.store
        _ = store.backdropRevision.value
        let tokens = store.tokens
        let selection = scope.backdropSelection
        let tint = scope.backdropTintOpacity ?? tokens.wallpaperTintOpacity
        let appearance = appearance(input: store.input, tokens: tokens, accentFollowsArt: store.accentFollowsArt, tint: tint,
                                    terminal: store.terminalConfigLines)
        let picture = selection.flatMap { $0.resolvedImageURL(dark: tokens.isDark) }
        return Shown(appearance: appearance, picture: picture, dark: tokens.isDark)
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
                if let picture = shown.picture {
                    let dark = shown.dark
                    // Decoding a picture never runs on the main actor.
                    appearance.wallpaper = await Task.detached(priority: .utility) {
                        BackdropImageStore.phoneCopy(of: picture, dark: dark, in: folder)
                    }.value
                }
                guard !Task.isCancelled, let iphone else { return }
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
