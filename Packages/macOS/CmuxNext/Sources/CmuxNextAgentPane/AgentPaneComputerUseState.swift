public import CmuxNextActions
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

    /// Whether `prompt` names `@computer-use` (or `$computer-use`) as a tool, for a native field with no page to
    /// decide it (New Tab's). Simple and conservative next to the page's parser (toolMentions.ts): a whole word,
    /// any case, outside backticks (inline code and fences both split on them); `me@computer-use.dev`,
    /// `@computer-use.md` and `@computer-user` are not a mention.
    public static func isNamed(in prompt: String) -> Bool {
        let outsideCode = prompt.split(separator: "`", omittingEmptySubsequences: false).enumerated().filter { $0.offset.isMultiple(of: 2) }
        return outsideCode.contains { _, part in
            let text = Array(part.lowercased())
            let word = Array("computer-use")
            func wordy(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" }
            for index in text.indices where (text[index] == "@" || text[index] == "$") && text.count - index > word.count {
                guard Array(text[(index + 1)...(index + word.count)]) == word else { continue }
                if index > 0, wordy(text[index - 1]) || text[index - 1] == "." || text[index - 1] == "@" { continue }
                let after = index + word.count + 1
                if after < text.count, wordy(text[after]) || (text[after] == "." && after + 1 < text.count && wordy(text[after + 1])) { continue }
                return true
            }
            return false
        }
    }
}

/// Computer Use's state on every agent page: each page gets it at load and again on every change of
/// the App's setup, so the page never asks and never decides on a stale answer. One per app, made with
/// ``AgentPaneShared`` at the composition root and handed to each pane's model. Not an AgentPaneView
/// extension: that type is at its size limit.
///
/// Each pane's transport follows it too (``follow(_:)``): its local acpmux connection hears the state
/// (`_acpmux/computer_use_state`) once the connection is up and on every change, so acpmux holds a prompt that names
/// `@computer-use` while it is not ready; and its prompt journal replays the prompts it held once Computer Use is ready.
@MainActor
public final class AgentPaneComputerUse {
    /// Follows `read` (the App's Computer Use Setup) for the app's life; nil (tests) follows nothing.
    init(read: (@MainActor () -> AgentPaneComputerUseState?)? = nil) {
        follow(read)
    }

    /// The state now; nil until the App's setup answered (a test host, or before the first view).
    public private(set) var state: AgentPaneComputerUseState?
    /// The pages told so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()
    /// The pane transports that tell their daemon the state and replay held prompts once it is ready, held weakly.
    private let transports = NSHashTable<AgentPaneTransport>.weakObjects()
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

    /// Takes `next` and pushes it to every page and every pane connection told so far, a change only. Ready replays
    /// each transport's held prompts, after its daemon heard the state.
    func set(_ next: AgentPaneComputerUseState?) {
        guard next != state else { return }
        state = next
        for view in views.allObjects { send(to: view) }
        for transport in transports.allObjects {
            transport.tellComputerUseState()
            if next == .ready { transport.replayHeldPrompts() }
        }
    }

    /// `transport` follows the state from now on (``AgentPaneTransport/computerUse``).
    func follow(_ transport: AgentPaneTransport) {
        transports.add(transport)
        transport.computerUse = self
        transport.tellComputerUseState()
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

    /// A native New Tab submit of `prompt` (`NewTabPage.submitNative`), decided at the submit as the page decides a
    /// send: true when it must not open a chat. A prompt that names `@computer-use` (``AgentPaneComputerUseState/isNamed(in:)``)
    /// while Computer Use is known and not ready runs Set Up Computer Use as the person's own run from this submit (the
    /// chat it would open could not: its first gesture is gone with the closed page), or, when the organization turned
    /// it off, refuses with `refusal`. The caller keeps the page and its typed text. Unknown (nil) or ready lets it go,
    /// and so does a page whose chat starts on another machine (`startsRemote`, ``AgentPaneNewTab/startsRemote``): this
    /// Mac's setup is not that machine's.
    public func holdsSubmit(_ prompt: String, startsRemote: Bool = false, registry: ActionRegistry, refusal: String) -> Bool {
        guard !startsRemote, let state, state != .ready, AgentPaneComputerUseState.isNamed(in: prompt) else { return false }
        if state == .disabled {
            registry.refuse(refusal)
        } else {
            _ = registry.perform(ActionID(rawValue: AgentPaneComputerUseState.setupAction), invocation: ActionInvocation(origin: .user))
        }
        return true
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
