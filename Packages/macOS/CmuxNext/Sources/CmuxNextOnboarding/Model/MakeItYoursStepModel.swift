public import Foundation
public import Observation

/// How a new person wants to work in cmux (cmux#48416): GUI-first, the recommended default (agent
/// chats, browsers and terminals side by side, a new tab starts a chat and Chief is in the sidebar),
/// or terminal-first (a new tab opens a terminal, and cmux stays out of the way).
public enum WorkStyle: String, CaseIterable, Sendable {
    case gui, terminal
}

/// The first run's density choice: the three of the five `appearance.density` levels a new person can
/// tell apart at a glance (ultra-compact and spacious stay in Settings).
public enum DensityChoice: String, CaseIterable, Sendable {
    case compact, standard, comfortable
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

/// The choices of the Make cmux Yours step.
public struct FirstRunChoices: Sendable, Equatable {
    public var workStyle: WorkStyle
    public var density: DensityChoice
    /// The background's id (`appearance.background`); nil: none.
    public var background: String?

    /// GUI-first, standard density, no background: what a person gets who skips.
    public static let recommended = FirstRunChoices(workStyle: .gui, density: .standard, background: nil)

    public init(workStyle: WorkStyle, density: DensityChoice, background: String?) {
        self.workStyle = workStyle
        self.density = density
        self.background = background
    }
}

/// What the Make cmux Yours step reads and writes; the App implements it over its settings.
@MainActor
public protocol FirstRunChoicesSource: AnyObject {
    /// The settings now, as the step's choices.
    func currentChoices() -> FirstRunChoices
    /// The built-in backgrounds offered, in order (the step adds None first).
    func backgrounds() async -> [FirstRunBackground]
    /// Writes what changed from `old` to `new` now, so the app behind the window shows it at once.
    func apply(_ new: FirstRunChoices, from old: FirstRunChoices)
}

/// The first run's one setup screen (cmux#48416): how the person wants to work, the density, and a
/// background. No theme row: windows follow macOS's light or dark mode, and cmux has no setting of its own for it. Short on purpose: three rows, each already on the recommended answer, so Continue alone is a
/// good setup. Every pick is written at once (the window behind shows it); Skip puts back what was set when the step
/// opened (`revert()`).
@MainActor
@Observable
public final class MakeItYoursStepModel {
    public private(set) var choices: FirstRunChoices = .recommended
    public private(set) var backgrounds: [FirstRunBackground] = []
    /// The first read answered.
    public private(set) var loaded = false

    @ObservationIgnored public let source: (any FirstRunChoicesSource)?
    @ObservationIgnored private var read: Task<Void, Never>?
    /// The choices the step first read: what Skip writes back.
    @ObservationIgnored private var opened: FirstRunChoices?

    public init(source: (any FirstRunChoicesSource)?) {
        self.source = source
    }

    /// Reads the settings and the backgrounds; writes nothing.
    public func start() {
        guard let source else {
            loaded = true
            return
        }
        choices = source.currentChoices()
        if opened == nil { opened = choices }
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

    public func setWorkStyle(_ value: WorkStyle) { update { $0.workStyle = value } }
    public func setDensity(_ value: DensityChoice) { update { $0.density = value } }

    /// `id` nil: no background. An id the step does not offer is refused.
    @discardableResult
    public func setBackground(_ id: String?) -> Bool {
        guard id == nil || backgrounds.contains(where: { $0.id == id }) else { return false }
        update { $0.background = id }
        return true
    }

    /// Skip: writes back what was set when the step opened, in one change, so the person keeps their
    /// settings. Nothing picked: nothing written.
    public func revert() {
        guard let opened else { return }
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
