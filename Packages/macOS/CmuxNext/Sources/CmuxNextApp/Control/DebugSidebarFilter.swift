import CmuxNextSettings

/// `debug.sidebar_filter {text, window?}`: sets the filter text (no UI writes it), to test reorder while filtering.
@MainActor
enum DebugSidebarFilter {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let controller = services.windows.controllers.first { c in params["window"]?.stringValue.map { $0 == c.state.id } ?? true }
        controller?.sidebar.model.filterText = params["text"]?.stringValue ?? ""
        return .object(["window": controller.map { .string($0.state.id) } ?? .null])
    }
}
