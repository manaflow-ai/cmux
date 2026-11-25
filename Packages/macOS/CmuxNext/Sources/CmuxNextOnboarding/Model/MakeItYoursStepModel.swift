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

    /// GUI-first, Default density, no background, the theme's opacity and material: what a person
    /// gets who skips on a new Mac.
    public static let recommended = FirstRunChoices(workStyle: .gui, density: defaultDensity, background: nil)
    /// Settings' Default density.
    public static let defaultDensity = "cozy"

    public init(workStyle: WorkStyle, density: String, background: String?, opacity: Double? = nil, material: FirstRunMaterial? = nil) {
        self.workStyle = workStyle
        self.density = density
        self.background = background
        self.opacity = opacity.map { min(max($0, 0), 1) }
        self.material = material
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
    /// Writes what changed from `old` to `new` now, in one publish, so the app behind the window
    /// shows it at once and never half of it.
    func apply(_ new: FirstRunChoices, from old: FirstRunChoices)
    /// The step opened: read what every pick may write (linked edits included), for Skip.
    func markOpened()
    /// Skip: puts back what `markOpened` read, in one publish. False when it has nothing to put back
    /// (the step then writes its opening choices with `apply`).
    func restoreOpened() -> Bool
    /// `handler` runs when a write is refused or fails, with what went wrong.
    func observeWriteFailures(_ handler: @escaping @MainActor (String) -> Void)
}

public extension FirstRunChoicesSource {
    func shownOpacity() -> Double? { nil }
    func markOpened() {}
    func restoreOpened() -> Bool { false }
    func observeWriteFailures(_ handler: @escaping @MainActor (String) -> Void) {}
}

/// The first run's one setup screen (cmux#48416): how the person wants to work, the density, and a
/// background with its opacity and material. No theme row: windows follow macOS's light or dark mode,
/// and cmux has no setting of its own for it. Every row is already on the recommended answer, so
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
    /// The last write the settings refused or that failed (nil: every write landed). The choices are
    /// read again then, so the page shows what the settings hold.
    public private(set) var writeFailure: String?

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
            source.markOpened()
            source.observeWriteFailures { [weak self] reason in
                guard let self, let source = self.source else { return }
                writeFailure = reason
                choices = source.currentChoices()
            }
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

    /// Skip: puts back what was set when the step opened, in one write, so the person keeps their
    /// settings exactly (the linked edits a pick made too).
    public func revert() {
        guard let opened else { return }
        if source?.restoreOpened() == true {
            choices = opened
            return
        }
        update { $0 = opened }
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
