import CmuxMobileShellModel

struct TerminalPickerMenuRow: Identifiable, Equatable {
    enum ID: Hashable {
        case terminal(MobileTerminalPreview.ID)
        case macSurface(MobileSurfacePreview.ID)
    }
    let id: ID
    let name: String
    let surfaceKind: MobileSurfacePreview.Kind

    init(_ terminal: MobileTerminalPreview) {
        id = .terminal(terminal.id)
        name = terminal.name
        surfaceKind = .terminal
    }

    init(_ surface: MobileSurfacePreview) {
        id = .macSurface(surface.id)
        name = surface.title
        surfaceKind = surface.kind
    }

    var terminalID: MobileTerminalPreview.ID? {
        guard case let .terminal(id) = id else { return nil }
        return id
    }

    var macSurfaceID: MobileSurfacePreview.ID? {
        guard case let .macSurface(id) = id else { return nil }
        return id
    }
}

extension Collection where Element == TerminalPickerMenuRow {
    func resolvedTerminalPickerSelection(
        selectedID: MobileTerminalPreview.ID?
    ) -> (id: MobileTerminalPreview.ID, name: String)? {
        if let selectedID,
           let selected = first(where: { $0.id == .terminal(selectedID) }) {
            return (id: selectedID, name: selected.name)
        }
        guard let first = first(where: { if case .terminal = $0.id { true } else { false } }),
              case let .terminal(id) = first.id else { return nil }
        return (id: id, name: first.name)
    }
}

extension WorkspaceDetailView {
    var hasTitleMenuActions: Bool {
        customizeWorkspace != nil
            || workspace.actionCapabilities.supportsWorkspaceActions
            || workspace.actionCapabilities.supportsReadStateActions
            || closeWorkspace != nil
    }
}
