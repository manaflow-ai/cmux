public import AppKit
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

    /// A machine header menu's screen rows its screen button does not offer (``SidebarMachine/screenAction``, the
    /// button's rule): Share This Mac only where the button is Share (This Mac), View Screen only where it is View and
    /// can run (Cloud, or a Mac whose screen device is online), neither on a Linux or unidentified SSH machine.
    public static func hiddenMenuRows(_ header: SidebarMachine?) -> Set<ActionID> {
        let share: ActionID = "macScreen.shareThisMac", view: ActionID = "machine.viewScreen"
        switch header?.screenAction {
        case .shareScreen?: return [view]
        case .viewScreen? where header?.screenActionEnabled == true: return [share]
        default: return [share, view]
        }
    }

    /// The single-machine sidebar's "Projects" title menu (the sidebar's own menu) with This Mac's Share This Mac row on
    /// top, the row its machine header menu has when other machines are listed, so whichever header is shown offers
    /// sharing. Returns `menu` unchanged when the registry has no such row (an administrator turned the action off).
    @discardableResult
    public static func addShareThisMacRow(to menu: NSMenu, registry: ActionRegistry) -> NSMenu {
        guard let share = registry.makeContextMenuItem(for: "macScreen.shareThisMac", in: .machineSection) else { return menu }
        menu.insertItem(share, at: 0)
        if menu.items.count > 1, !menu.items[1].isSeparatorItem { menu.insertItem(.separator(), at: 1) }
        return menu
    }

    /// Binds View Screen (`machine.viewScreen`), a machine header menu's row (Leo 2026-11-14: "ok but in screen sharing
    /// we also want the interaction pathways better"): it sends the header button's own `.viewScreen` intent through
    /// `window`'s sidebar (its sections and intent handler), so a Cloud machine opens its desktop and a Mac its Screen
    /// Sharing tab exactly as the button does. Share This Mac's row is `macScreen.shareThisMac`, the action Share runs.
    public static func bindViewScreen(into registry: ActionRegistry,
                                      window: @escaping @MainActor () -> (sections: [SidebarSection], handle: @MainActor (SidebarIntent) -> Void)?) {
        registry.bindEffect("machine.viewScreen") { invocation in
            guard let id = invocation.target?.id, let window = window(),
                  let machine = window.sections.first(where: { $0.machine?.id.rawValue == id })?.machine,
                  case .viewScreen? = machine.screenAction, machine.screenActionEnabled
            else { return .refused(String(localized: "screen.refusal.noScreen", defaultValue: "this window's sidebar has no screen to view on that machine", table: "SidebarReveal", bundle: .module)) }
            window.handle(.viewScreen(machine.id))
            return .done
        }
    }
}
