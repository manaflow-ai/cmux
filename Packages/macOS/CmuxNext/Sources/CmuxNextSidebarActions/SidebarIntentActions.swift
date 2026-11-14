public import CmuxNextActions
public import CmuxNextSidebar

/// The sidebar intents that only run a catalog action, as the person's own gesture: the space bar's New Space and
/// Open in New Window, and the machine headers' screen buttons (`SidebarIntent.viewScreen` / `.shareScreen`).
///
/// View screen on a Cloud machine opens its desktop (`cloudOpenDesktop` on that machine). Share on This Mac turns
/// sharing on at once (`macScreen.shareThisMac`) only where that also asks for Screen Recording, which is cmux
/// Remote's host; otherwise it opens Screen Sharing (`macScreen.open`), whose Allow Mac Screen switch walks the
/// person through the permissions and sign-in. SSH and server machines show no screen button.
@MainActor
public struct SidebarIntentActions {
    private let perform: (ActionID, ActionInvocation) -> Void
    private let sharesDirectly: () -> Bool

    /// - Parameters:
    ///   - perform: Runs an action (the App's registry).
    ///   - sharesDirectly: Whether `macScreen.shareThisMac` can do the whole job now: it is available and cmux Remote,
    ///     which asks for Screen Recording, runs in this build (Release and NIGHTLY embed none).
    public init(perform: @escaping (ActionID, ActionInvocation) -> Void, sharesDirectly: @escaping () -> Bool) {
        self.perform = perform
        self.sharesDirectly = sharesDirectly
    }

    /// Runs on `registry`; Share This Mac shares directly when `remoteRuns` and the action is available.
    public init(registry: ActionRegistry, remoteRuns: Bool) {
        let share: ActionID = "macScreen.shareThisMac"
        self.init(perform: { _ = registry.perform($0, invocation: $1) }, sharesDirectly: {
            remoteRuns && registry.isAvailable(share) && registry.unavailableReason(for: share) == nil
        })
    }

    public func handle(_ intent: SidebarIntent, sections: [SidebarSection]) {
        switch intent {
        case .newProfile:
            perform("space.new", ActionInvocation())
        case .openProfileInNewWindow(let profile):
            perform("space.openInNewWindow", ActionInvocation(target: ActionTargetRef(kind: .profile, id: profile.rawValue), origin: .user))
        case .viewScreen(let machine):
            guard Self.kind(of: machine, in: sections) == .cloud else { return }
            perform("cloudOpenDesktop", ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine.rawValue), origin: .user))
        case .shareScreen(let machine):
            // Only This Mac shares from here: a remote machine's header cannot share this Mac.
            guard Self.kind(of: machine, in: sections) == .local else { return }
            perform(sharesDirectly() ? "macScreen.shareThisMac" : "macScreen.open", ActionInvocation(origin: .user))
        default:
            break
        }
    }

    private static func kind(of machine: MachineID, in sections: [SidebarSection]) -> SidebarMachine.Kind? {
        sections.first { $0.machine?.id == machine }?.machine?.kind
    }
}
