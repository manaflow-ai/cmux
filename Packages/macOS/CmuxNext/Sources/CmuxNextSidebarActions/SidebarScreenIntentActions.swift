public import CmuxNextActions
public import CmuxNextSidebar

/// Routes the sidebar's screen controls using the authenticated identity projected onto its sections.
/// The App supplies the window-specific Mac tab opener; action dispatch preserves a person's origin.
@MainActor
public struct SidebarScreenIntentActions {
    private let perform: (ActionID, ActionInvocation) -> Void

    public init(perform: @escaping (ActionID, ActionInvocation) -> Void) {
        self.perform = perform
    }

    public func handle(_ intent: SidebarIntent, sections: [SidebarSection], openMacScreen: (String) -> Void) {
        switch intent {
        case .viewScreen(let machine):
            guard let header = sections.first(where: { $0.machine?.id == machine })?.machine else { return }
            if header.kind == .cloud {
                perform("cloudOpenDesktop", ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine.rawValue), origin: .user))
            } else if let device = header.screenDeviceID, header.screenAvailable {
                openMacScreen(device)
            }
        case .shareScreen(let machine):
            guard machine == .local else { return }
            perform("macScreen.shareThisMac", ActionInvocation(origin: .user))
        default:
            break
        }
    }
}
