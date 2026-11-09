import CmuxNextCompat
public import Observation

/// First-run setup's rows for the sidebar's "Finish setting up" card (Lawrence msg 25425: the Set Up cmux card
/// floated over Home's chat; it docks in every window's sidebar instead). One per app: while ``FirstRunSetup``
/// shows, it holds the setup model (``SetupCardPageProvider``, whose agent installs and reads run once for every
/// window) and ends the setup once every row is done.
///
/// ```swift
/// let checklist = SetupChecklist(setup: setup, agents: harnesses, environment: { appEnvironment() })
/// checklist.start()
/// checklist.steps // the rows while setup shows, nil after
/// ```
@MainActor
@Observable
public final class SetupChecklist {
    @ObservationIgnored private let setup: FirstRunSetup
    @ObservationIgnored private let agents: (any AgentSignInSource)?
    @ObservationIgnored private let environment: @MainActor () -> SetupCardEnvironment
    /// The setup model while the card shows; nil once it ended (hidden or done).
    public private(set) var model: SetupCardPageProvider?
    @ObservationIgnored private var showsWatch: Task<Void, Never>?
    @ObservationIgnored private var completionWatch: Task<Void, Never>?

    /// - Parameters:
    ///   - setup: Whether setup shows; the x and every row done end it.
    ///   - agents: The agents' installs and sign-ins (acpmux's harnesses).
    ///   - environment: What the rows read and run that only the App has; made when the card first shows.
    public init(setup: FirstRunSetup, agents: (any AgentSignInSource)?, environment: @escaping @MainActor () -> SetupCardEnvironment) {
        self.setup = setup
        self.agents = agents
        self.environment = environment
    }

    /// Starts following ``FirstRunSetup/shows``; idempotent (each window's sidebar asks).
    public func start() {
        guard showsWatch == nil else { return }
        let setup = setup
        // task-owner: lives as long as the app (OnboardingService holds this); event-driven (Observation).
        showsWatch = Task { [weak self] in
            for await shows in ObservationStream({ setup.shows }) {
                guard let self, !Task.isCancelled else { return }
                show(shows)
            }
        }
    }

    private func show(_ shows: Bool) {
        guard shows else {
            completionWatch?.cancel()
            completionWatch = nil
            model?.stop()
            model = nil
            return
        }
        guard model == nil else { return }
        let model = SetupCardPageProvider(setup: setup, agents: agents, environment: environment())
        self.model = model
        let setup = setup
        // task-owner: ends with the card (show(false)); event-driven (Observation of the rows).
        completionWatch = Task { [weak model] in
            for await done in ObservationStream({ model?.isComplete ?? false }) where done {
                setup.end()
                return
            }
        }
    }

    /// The rows while setup shows; nil hides the card.
    public var steps: [SetupChecklistStep]? { model?.checklist }

    /// A row's or the button's click (`id`: a ``SetupChecklistStep/Kind`` raw value).
    public func run(_ id: String) {
        guard let kind = SetupChecklistStep.Kind(rawValue: id) else { return }
        model?.perform(kind)
    }

    /// The window with the card became key (back from a sign-in in Terminal or a browser): read the rows again.
    public func refresh() {
        model?.refresh()
    }

    /// The card's x: setup ends for good (``FirstRunSetup/end()``).
    public func hide() {
        setup.end()
    }
}
