import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Every toggle the app binds says which way it points (Lawrence 2026-10-27: "Pin/Unpin Workspace"
/// did not say whether the workspace was pinned). A toggle with ``ActionToggleTitles`` and no
/// state closure would show its off title even while on, so each bound one must have one.
@MainActor @Suite(.serialized)
struct ToggleStateCoverageTests {
    @Test func everyBoundToggleReadsItsState() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let registry = services.registry
        let missing = registry.entries
            .filter { $0.descriptor.toggleTitles != nil && $0.action != nil && $0.action?.targetState == nil }
            .map(\.descriptor.id.rawValue)
        #expect(missing.isEmpty, "Bind ActionTargetTitles.setState for: \(missing.joined(separator: ", "))")
    }

    @Test func aToggleReadWithNothingFocusedShowsNoNotice() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let registry = services.registry
        var notices: [String] = []
        registry.refusalObserver = { reason, _ in notices.append(reason) }
        for entry in registry.entries where entry.descriptor.toggleTitles != nil {
            _ = registry.displayTitle(for: entry.descriptor.id)
        }
        #expect(notices.isEmpty, "\(notices)")
    }
}
