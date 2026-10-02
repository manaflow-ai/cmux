import CmuxNextActions
import CmuxNextSidebar
import Foundation
import Observation

/// The user's sidebar section layout as this app shows it
/// (plans/cmux-next/sidebar-sections.md 5). The workspace store owns the
/// document (`sidebar-layout-v1`); until the home daemon serves it, the app
/// shows the defaults and refuses edits, except in DEV with Debug Settings
/// `sidebar.sections.localPrototype`, which edits an in-memory copy that is
/// never saved. Every window's sidebar renders `document`.
@Observable @MainActor
final class SidebarLayoutService {
    /// The capability the store serves the layout under.
    static let capability = "sidebar-layout-v1"

    private(set) var document: SidebarLayoutDocument = .defaults
    @ObservationIgnored private var prototype = SidebarLayoutMemoryOwner()
    @ObservationIgnored private let prototypeEnabled: @MainActor () -> Bool

    init(prototypeEnabled: @escaping @MainActor () -> Bool = {
        DevTools.isEnabled && SidebarSectionTunables.localPrototype.override == true
    }) {
        self.prototypeEnabled = prototypeEnabled
    }

    /// Why edits are refused now, or nil when they apply.
    var unavailableReason: String? {
        prototypeEnabled() ? nil : RefusalStrings.needsDaemonCapability(Self.capability)
    }

    /// Applies `op`. Throws the refusal when edits are unavailable or the
    /// owner rejects the op (an invariant of sections.md 4).
    func send(_ op: SidebarLayoutOp) throws {
        if let reason = unavailableReason { throw ActionFailure(message: reason) }
        switch prototype.apply(op, key: UUID().uuidString) {
        case .success(let next):
            if next != document { document = next }
        case .failure(let reject):
            throw ActionFailure(message: SidebarSectionStrings.rejected(reject.rawValue))
        }
    }
}
