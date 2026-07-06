import CmuxControlSocket
import Foundation

extension TerminalController: ControlLayoutContext {
    func controlLayoutSave(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        name: String,
        description: String?,
        overwrite: Bool
    ) -> ControlLayoutSaveResolution {
        let resolution = v2MainSync { () -> ControlLayoutSaveResolution in
            guard let workspace = controlLayoutWorkspace(routing: routing, workspaceID: workspaceID) else {
                return .workspaceNotFound
            }
            let capture = workspace.captureLayoutDefinition()
            let store = SavedLayoutStore()
            let layout = CmuxSavedLayout(
                name: name,
                description: description,
                workspace: capture.workspace
            )
            do {
                try store.save(layout, overwrite: overwrite)
                return .saved(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    path: store.fileURL.path,
                    unsupportedSurfaceCount: capture.unsupportedSurfaceCount
                )
            } catch let error as SavedLayoutStoreError {
                return controlLayoutSaveError(error)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return resolution
    }

    func controlLayoutList() -> ControlLayoutListResolution {
        v2MainSync {
            let store = SavedLayoutStore()
            do {
                let summaries = try store.list().map { layout in
                    let counts = Self.controlLayoutCounts(layout.workspace.layout)
                    return ControlSavedLayoutSummary(
                        name: layout.name,
                        description: layout.description,
                        paneCount: counts.panes,
                        surfaceCount: counts.surfaces
                    )
                }
                return .resolved(summaries)
            } catch let error as SavedLayoutStoreError {
                return controlLayoutListError(error)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    func controlLayoutGet(name: String) -> ControlLayoutGetResolution {
        v2MainSync {
            let store = SavedLayoutStore()
            do {
                guard let layout = try store.layout(named: name) else {
                    return .notFound
                }
                guard let payload = Self.controlLayoutJSONValue(layout) else {
                    return .failed("Failed to encode saved layout")
                }
                return .resolved(payload)
            } catch let error as SavedLayoutStoreError {
                return controlLayoutGetError(error)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    func controlLayoutOpen(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        focusRequested: Bool
    ) -> ControlLayoutOpenResolution {
        v2MainSync {
            let store = SavedLayoutStore()
            do {
                guard let layout = try store.layout(named: name) else {
                    return .layoutNotFound
                }
                guard let tabManager = resolveTabManager(routing: routing) else {
                    return .tabManagerUnavailable
                }
                let focus = v2FocusAllowed(requested: focusRequested)
                guard let workspace = tabManager.openWorkspace(fromSavedLayout: layout, cwdOverride: cwd, focus: focus) else {
                    return .failed("Failed to open saved layout")
                }
                return .opened(workspaceID: workspace.id)
            } catch let error as SavedLayoutStoreError {
                return controlLayoutOpenError(error)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    func controlLayoutDelete(name: String) -> ControlLayoutDeleteResolution {
        v2MainSync {
            let store = SavedLayoutStore()
            do {
                try store.delete(named: name)
                return .deleted
            } catch let error as SavedLayoutStoreError {
                return controlLayoutDeleteError(error)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private func controlLayoutWorkspace(routing: ControlRoutingSelectors, workspaceID: UUID?) -> Workspace? {
        if let workspaceID,
           let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) {
            return tabManager.tabs.first { $0.id == workspaceID }
        }
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let workspaceID {
            return tabManager.tabs.first { $0.id == workspaceID }
        }
        return tabManager.selectedWorkspace
    }

    private func controlLayoutSaveError(_ error: SavedLayoutStoreError) -> ControlLayoutSaveResolution {
        switch error {
        case .blankName:
            return .failed("Missing or blank name")
        case .duplicateName:
            return .alreadyExists
        case .notFound:
            return .workspaceNotFound
        case .corruptFile(let description):
            return .corruptFile(description)
        }
    }

    private func controlLayoutListError(_ error: SavedLayoutStoreError) -> ControlLayoutListResolution {
        switch error {
        case .corruptFile(let description):
            return .corruptFile(description)
        case .blankName, .duplicateName, .notFound:
            return .failed("\(error)")
        }
    }

    private func controlLayoutGetError(_ error: SavedLayoutStoreError) -> ControlLayoutGetResolution {
        switch error {
        case .notFound:
            return .notFound
        case .corruptFile(let description):
            return .corruptFile(description)
        case .blankName:
            return .notFound
        case .duplicateName:
            return .failed("\(error)")
        }
    }

    private func controlLayoutOpenError(_ error: SavedLayoutStoreError) -> ControlLayoutOpenResolution {
        switch error {
        case .notFound, .blankName:
            return .layoutNotFound
        case .corruptFile(let description):
            return .corruptFile(description)
        case .duplicateName:
            return .failed("\(error)")
        }
    }

    private func controlLayoutDeleteError(_ error: SavedLayoutStoreError) -> ControlLayoutDeleteResolution {
        switch error {
        case .notFound, .blankName:
            return .notFound
        case .corruptFile(let description):
            return .corruptFile(description)
        case .duplicateName:
            return .failed("\(error)")
        }
    }

    private static func controlLayoutCounts(_ node: CmuxLayoutNode?) -> (panes: Int, surfaces: Int) {
        guard let node else { return (0, 0) }
        switch node {
        case .pane(let pane):
            return (1, pane.surfaces.count)
        case .split(let split):
            return split.children
                .map { Self.controlLayoutCounts($0) }
                .reduce((0, 0)) { partial, next in
                    (partial.panes + next.panes, partial.surfaces + next.surfaces)
                }
        }
    }

    private static func controlLayoutJSONValue(_ layout: CmuxSavedLayout) -> JSONValue? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(layout),
              let object = try? JSONSerialization.jsonObject(with: data),
              let value = JSONValue(foundationObject: object) else {
            return nil
        }
        return value
    }
}
