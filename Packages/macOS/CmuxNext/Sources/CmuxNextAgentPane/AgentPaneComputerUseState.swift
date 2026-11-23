import CmuxNextCompat
import CmuxNextSettings
import Foundation

/// Whether computer use is set up on this Mac, for the composer's `@computer-use` (CMUX-682,
/// Lawrence and Lucas 2026-11-20: "@computer use" is always in the @ menu; a send that names it
/// while it is not set up opens Set Up Computer Use instead). The App's one `ComputerUseSetup`
/// answers through ``AgentPaneShared/computerUseState``; ``AgentPaneComputerUse`` pushes it to every
/// page as it changes (`computerUseState` event), so a send decides on the state as it is now, at once.
public nonisolated enum AgentPaneComputerUseState: String, Sendable, Equatable {
    /// The helper answered and holds Accessibility and Screen Recording.
    case ready
    /// The helper is starting or has not answered yet: not working yet, so the page holds the send.
    case starting
    /// Off, missing a grant or failed: Set Up Computer Use fixes it (its page has Restart).
    case needsSetup = "needs_setup"
    /// This build has no cmux Remote, or its cmux Remote answers in another version's shape: no setup
    /// can fix it, only another build (#48541).
    case unavailable
    /// The organization turned computer use off: no setup can help.
    case disabled

    /// The state of the App's Computer Use Setup: its phase (`ComputerUseSetup.Phase`'s raw value)
    /// and whether the helper holds both Accessibility and Screen Recording.
    public init(phase: String, granted: Bool) {
        switch phase {
        case "ready": self = granted ? .ready : .needsSetup
        case "starting": self = .starting
        case "disabled_by_policy": self = .disabled
        case "unavailable", "version_mismatch": self = .unavailable
        default: self = .needsSetup
        }
    }

    /// The action the page runs for Set Up Computer Use (`action.run`): the onboarding step that
    /// turns computer use on and asks for both grants (AgentHandlers, `palette.computerUse.setup`).
    public static let setupAction = "palette.computerUse.setup"
}

/// Computer Use's state on every agent page: each page gets it at load and again on every change of
/// the App's setup, so the page never asks and never decides on a stale answer. One per app, made with
/// ``AgentPaneShared`` at the composition root and handed to each pane's model. Not an AgentPaneView
/// extension: that type is at its size limit.
@MainActor
public final class AgentPaneComputerUse {
    /// Follows `read` (the App's Computer Use Setup) for the app's life; nil (tests) follows nothing.
    init(read: (@MainActor () -> AgentPaneComputerUseState?)? = nil) {
        follow(read)
    }

    /// The state now; nil until the App's setup answered (a test host, or before the first view).
    private(set) var state: AgentPaneComputerUseState?
    /// The pages told so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()
    /// Follows the App's setup for the app's life once a view brought its reader (idempotent).
    private var following: Task<Void, Never>?

    /// Follows `read` from now on, once.
    private func follow(_ read: (@MainActor () -> AgentPaneComputerUseState?)?) {
        guard following == nil, let read else { return }
        // task-owner: the app-wide follower of one main-actor model, for the app's life; it only stores
        // the state and pushes it to the open pages.
        following = Task { [weak self] in
            for await next in ObservationStream({ read() }) {
                guard let self else { return }
                set(next)
            }
        }
    }

    /// Takes `next` and pushes it to every page told so far, a change only.
    func set(_ next: AgentPaneComputerUseState?) {
        guard next != state else { return }
        state = next
        for view in views.allObjects { send(to: view) }
    }

    /// The state, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        views.add(view)
        return .computerUseState(state)
    }

    /// Gives `view`'s page the state now (a page that just loaded, on either host) and every change
    /// after: the old WebKit host (`agent.pageHost` off, the default) never reads ``event(for:)``.
    func push(to view: AgentPaneView) {
        views.add(view)
        send(to: view)
    }

    private func send(to view: AgentPaneView) {
        view.deliver([.computerUseState(state)], scripts: [Self.oldHostScript(state)])
    }

    /// The old host's script for the state (computerUseState.ts `window.cmuxAcpmuxComputerUseState`).
    static func oldHostScript(_ state: AgentPaneComputerUseState?) -> String {
        "window.cmuxAcpmuxComputerUseState?.(\(AgentPageEvent.computerUseState(state).value.compactText));"
    }
}

extension AgentPageEvent {
    /// Computer Use's state on this Mac (`computerUseState`): its raw value, null while unknown.
    static func computerUseState(_ state: AgentPaneComputerUseState?) -> AgentPageEvent {
        AgentPageEvent(kind: "computerUseState", value: state.map { .string($0.rawValue) } ?? .null)
    }
}
