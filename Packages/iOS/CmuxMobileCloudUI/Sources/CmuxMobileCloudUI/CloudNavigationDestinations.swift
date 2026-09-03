#if os(iOS)
public import CmuxMobileCloud
public import SwiftUI

/// The route to a cloud terminal: the machine it lives on plus the terminal.
public struct CloudTerminalRoute: Hashable, Sendable {
    public var machine: CloudMachine
    public var terminal: CloudTerminalSummary

    public init(machine: CloudMachine, terminal: CloudTerminalSummary) {
        self.machine = machine
        self.terminal = terminal
    }
}

/// The route to the Cloud section itself.
public struct CloudSectionRoute: Hashable, Sendable {
    public init() {}
}

extension View {
    /// Registers every Cloud destination on the host's navigation stack.
    ///
    /// Apply this on the root content of the `NavigationStack` that shows
    /// ``CloudEntryRow``. Destinations declared on the root survive re-renders
    /// of pushed views; declaring them on a pushed view made the stack pop the
    /// catalog while the host list refreshed.
    public func cloudNavigationDestinations() -> some View {
        modifier(CloudNavigationDestinations())
    }
}

private struct CloudNavigationDestinations: ViewModifier {
    @Environment(\.cloudSessionController) private var controller

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: CloudSectionRoute.self) { _ in
                if let controller {
                    CloudSectionView(controller: controller)
                } else {
                    CloudTunnelUnavailableView()
                }
            }
            .navigationDestination(for: CloudMachine.self) { machine in
                if let controller {
                    CloudTerminalCatalogView(machine: machine, controller: controller)
                } else {
                    CloudTunnelUnavailableView()
                }
            }
            .navigationDestination(for: CloudTerminalRoute.self) { route in
                if let controller {
                    CloudTerminalScreen(machine: route.machine, terminal: route.terminal, controller: controller)
                } else {
                    CloudTunnelUnavailableView()
                }
            }
    }
}
#endif
