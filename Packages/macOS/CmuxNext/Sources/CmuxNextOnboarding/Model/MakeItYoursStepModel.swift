public import Foundation
public import Observation

/// How a new person wants to work in cmux (cmux#48416): GUI-first, the recommended default (agent
/// chats, browsers and terminals side by side, a new tab starts a chat and Chief is in the sidebar),
/// or terminal-first (a new tab opens a terminal, and cmux stays out of the way).
public enum WorkStyle: String, CaseIterable, Sendable {
    case gui, terminal
}

/// One density the step offers: a built-in `appearance.density` preset id and its name as Settings
/// shows it (cmux#49636: every density Settings has, not three of them).
public struct FirstRunDensity: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One background a new person can pick: none, or one of the built-in art (`id` is the background
/// setting's value). `preview` is a small image the page draws (a `data:` PNG), nil while it renders.
public struct FirstRunBackground: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var preview: String?

    public init(id: String, name: String, preview: String? = nil) {
        self.id = id
        self.name = name
        self.preview = preview
    }
}

/// One terminal theme the step offers (`appearance.theme`): `id` is the setting's value (a Ghostty
/// theme name, or a `light:<theme>,dark:<theme>` pair that follows macOS's appearance). `light` and
/// `dark` are its swatch strips (`#RRGGBB`: background, the six ANSI hues, foreground); a theme with one
/// side has the same strip on both; empty until the theme files are read.
public struct FirstRunTheme: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var light: [String]
    public var dark: [String]

    public init(id: String, name: String, light: [String] = [], dark: [String] = []) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
    }
}

/// The window's material under a background (`appearance.backgroundBlur`), as Settings offers it.
public enum FirstRunMaterial: String, CaseIterable, Sendable {
    case none, frosted, glass
    case glassClear = "glass-clear"
}

/// The choices of the Make cmux Yours step.
public struct FirstRunChoices: Sendable, Equatable {
    public var workStyle: WorkStyle
    /// The `appearance.density` preset id (`cozy` is Settings' Default).
    public var density: String
    /// The background's id (`appearance.background`); nil: none.
    public var background: String?
    /// `appearance.backgroundOpacity`, 0...1; nil: unset (the theme's).
    public var opacity: Double?
    /// `appearance.backgroundBlur`; nil: unset (the theme's).
    public var material: FirstRunMaterial?
    /// `appearance.metrics.chromeFontSize` in points; nil: unset (the density's).
    public var textSize: Double?
    /// `appearance.theme`; nil: unset (the Ghostty config's).
    public var theme: String?
    /// `appearance.accent`; nil: unset (Neutral).
    public var accent: String?
    /// `appearance.chromeStyle`; nil: unset (Flat).
    public var windowStyle: String?

    /// GUI-first, Default density, no background, the theme's opacity and material: what a person
    /// gets who skips on a new Mac.
    public static let recommended = FirstRunChoices(workStyle: .gui, density: defaultDensity, background: nil)
    /// Settings' Default density.
    public static let defaultDensity = "cozy"
    /// What an unset Accent and Window Style are (AccentSetting and ChromeStyleSetting's fallbacks).
    public static let defaultAccent = "neutral"
    public static let defaultWindowStyle = "flat"
    /// Every Accent Settings offers, in its order: ThemeAccent's cases, then Art Color.
    public static let accents = ["neutral", "theme", "red", "green", "yellow", "blue", "magenta", "cyan", "art"]
    /// Every Window Style Settings offers, in its order (ChromeStyle's cases).
    public static let windowStyles = ["default", "card", "card-outlined", "flat", "flat-sidebar-line", "bare", "panes", "two-tone", "floating", "blocks"]
    /// Text Size's range in points (InterfaceSizeSetting.range).
    public static let textSizes: ClosedRange<Double> = 10...20

    public init(workStyle: WorkStyle, density: String, background: String?, opacity: Double? = nil, material: FirstRunMaterial? = nil,
                textSize: Double? = nil, theme: String? = nil, accent: String? = nil, windowStyle: String? = nil) {
        self.workStyle = workStyle
        self.density = density
        self.background = background
        self.opacity = opacity.map { min(max($0, 0), 1) }
        self.material = material
        self.textSize = textSize.map { min(max($0, Self.textSizes.lowerBound), Self.textSizes.upperBound) }
        self.theme = theme
        self.accent = accent
        self.windowStyle = windowStyle
    }
}

/// What the Make cmux Yours step reads and writes; the App implements it over its settings.
@MainActor
public protocol FirstRunChoicesSource: AnyObject {
    /// The settings now, as the step's choices.
    func currentChoices() -> FirstRunChoices
    /// Every density offered, in Settings' order.
    func densities() -> [FirstRunDensity]
    /// The built-in backgrounds offered, in order (the step adds None first).
    func backgrounds() async -> [FirstRunBackground]
    /// The window opacity the app shows now, where an unset Opacity slider rests (Settings' own
    /// reading: over a picture, the tint the window lays over it). Read while the page's state is
    /// built, so an observable reading re-sends the state when it changes.
    func shownOpacity() -> Double?
    /// The terminal themes offered, in order (the step adds the Ghostty config's, unset, first). Read
    /// while the page's state is built, so the swatches show once the theme files are read.
    func themes() -> [FirstRunTheme]
    /// The text size in points `density` (a preset id) draws with when Text Size is unset.
    func textSize(density: String) -> Double?
    /// The color `accent` gives the window's theme (`#RRGGBB`), read while the page's state is built; nil: none to show.
    func accentSwatch(_ accent: String) -> String?
    /// Writes what changed from `old` to `new` now, so the app behind the window shows it at once.
    func apply(_ new: FirstRunChoices, from old: FirstRunChoices)
    /// Keeps what the person's own settings hold at every key the step writes, when the step opens.
    func keepForSkip()
    /// Skip: writes the kept settings back as they were, after any write in flight; false when none were kept.
    func putBack() -> Bool
}

public extension FirstRunChoicesSource {
    func shownOpacity() -> Double? { nil }
    func themes() -> [FirstRunTheme] { [] }
    func textSize(density: String) -> Double? { nil }
    func accentSwatch(_ accent: String) -> String? { nil }
    func keepForSkip() {}
    func putBack() -> Bool { false }
}

/// The first run's one setup screen (cmux#48416, cmux#49636): how the person wants to work, then the
/// look Settings > Appearance has: the density and text size, the terminal theme and the accent, the
/// window style, and a background with its opacity and material. Every row is already on the recommended answer, so
/// Continue alone is a good setup. Every pick is written at once (the window behind shows it);
/// Continue keeps them, Skip puts back what was set when the window opened (cmux#49636).
@MainActor
@Observable
public final class MakeItYoursStepModel {
    public private(set) var choices: FirstRunChoices = .recommended
    public private(set) var densities: [FirstRunDensity] = []
    public private(set) var backgrounds: [FirstRunBackground] = []
    /// The first read answered.
    public private(set) var loaded = false
    /// What was set when the step opened: Skip writes it back.
    public private(set) var opened: FirstRunChoices?

    @ObservationIgnored public let source: (any FirstRunChoicesSource)?
    @ObservationIgnored private var read: Task<Void, Never>?

    public init(source: (any FirstRunChoicesSource)?) {
        self.source = source
    }

    /// Reads the settings and the backgrounds; writes nothing.
    public func start() {
        guard let source else {
            loaded = true
            return
        }
        // The step shown again in the same window keeps its first baseline: Skip still puts back what was set before.
        if opened == nil {
            choices = source.currentChoices()
            opened = choices
            source.keepForSkip()
        }
        densities = source.densities()
        read?.cancel()
        // task-owner: one read of the built-in backgrounds' previews; stop() cancels it.
        read = Task { [weak self] in
            let found = await source.backgrounds()
            guard let self, !Task.isCancelled else { return }
            backgrounds = found
            loaded = true
        }
    }

    public func stop() {
        read?.cancel()
        read = nil
    }

    /// The Opacity slider's value: the one set, else what the window shows.
    public var shownOpacity: Double? { choices.opacity ?? source?.shownOpacity() }

    /// The Text Size slider's value: the one set, else the density's.
    public var shownTextSize: Double? { (choices.textSize ?? source?.textSize(density: choices.density)).map { $0.rounded() } }

    /// The terminal themes offered (their swatches as read now).
    public var themes: [FirstRunTheme] { source?.themes() ?? [] }

    /// Each Accent's color on the window's theme now (an accent with none is left out).
    public var accentSwatches: [String: String] {
        guard let source else { return [:] }
        return FirstRunChoices.accents.reduce(into: [:]) { swatches, accent in swatches[accent] = source.accentSwatch(accent) }
    }

    public func setWorkStyle(_ value: WorkStyle) { update { $0.workStyle = value } }

    /// An id the step does not offer is refused.
    @discardableResult
    public func setDensity(_ id: String) -> Bool {
        guard densities.contains(where: { $0.id == id }) else { return false }
        update { $0.density = id }
        return true
    }

    /// `id` nil: no background. An id the step does not offer is refused.
    @discardableResult
    public func setBackground(_ id: String?) -> Bool {
        guard id == nil || backgrounds.contains(where: { $0.id == id }) else { return false }
        update { $0.background = id }
        return true
    }

    /// The window's Opacity, 0...1 (a slider step); outside it is refused.
    @discardableResult
    public func setOpacity(_ value: Double) -> Bool {
        guard value.isFinite, (0...1).contains(value) else { return false }
        // The slider steps by 5%: a value the page rounded differently is still the same step.
        let stepped = (value * 100).rounded() / 100
        update { $0.opacity = stepped }
        return true
    }

    public func setMaterial(_ value: FirstRunMaterial) { update { $0.material = value } }

    /// Text Size in points, within ``FirstRunChoices/textSizes`` (whole points, Settings' step); nil puts
    /// back the density's. Outside the range is refused.
    @discardableResult
    public func setTextSize(_ value: Double?) -> Bool {
        if let value {
            guard value.isFinite, FirstRunChoices.textSizes.contains(value) else { return false }
            update { $0.textSize = value.rounded() }
        } else {
            update { $0.textSize = nil }
        }
        return true
    }

    /// `id` nil: the Ghostty config's theme. A theme the step does not offer is refused.
    @discardableResult
    public func setTheme(_ id: String?) -> Bool {
        guard id == nil || themes.contains(where: { $0.id == id }) else { return false }
        update { $0.theme = id }
        return true
    }

    @discardableResult
    public func setAccent(_ id: String) -> Bool {
        guard FirstRunChoices.accents.contains(id) else { return false }
        update { $0.accent = id }
        return true
    }

    @discardableResult
    public func setWindowStyle(_ id: String) -> Bool {
        guard FirstRunChoices.windowStyles.contains(id) else { return false }
        update { $0.windowStyle = id }
        return true
    }

    /// Skip: writes back what was set when the step opened, so the person keeps their settings.
    public func revert() {
        guard let opened else { return }
        // The source puts back the person's own file (a team's or theme file's value stays theirs);
        // a source that kept nothing gets the opening choices written back.
        if source?.putBack() == true { choices = opened } else { update { $0 = opened } }
    }

    private func update(_ change: (inout FirstRunChoices) -> Void) {
        var next = choices
        change(&next)
        guard next != choices else { return }
        let old = choices
        choices = next
        source?.apply(next, from: old)
    }
}
