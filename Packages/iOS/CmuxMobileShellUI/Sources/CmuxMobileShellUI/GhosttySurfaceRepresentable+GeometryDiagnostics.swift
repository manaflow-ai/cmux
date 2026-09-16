#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell

extension GhosttySurfaceRepresentable {
    var terminalWorkPopulation: TerminalWorkContext {
        .init(
            population: .mobileHost,
            workspaceCount: store.workspaces.count,
            surfaceCount: store.workspaces.reduce(0) { $0 + $1.surfaces.count }
        )
    }
}
#endif
