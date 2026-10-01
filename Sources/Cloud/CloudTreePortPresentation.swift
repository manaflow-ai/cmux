import CmuxSurfaceCatalogModel
import Foundation

/// Describes the port identity without adding an inline open action.
struct CloudTreePortPresentation {
    let resource: SurfaceResource
    let url: String?

    var title: String {
        guard let port = resource.id.forwardedPort ?? resource.port else { return resource.title }
        return ":\(port)"
    }

    var detail: String? {
        resource.detail
    }

    var toolTip: String? {
        detail ?? title
    }

    var accessibilityLabel: String {
        let portLabel: String
        if let port = resource.id.forwardedPort ?? resource.port {
            portLabel = String(format: String(localized: "cloudTree.port.title", defaultValue: "Port %@"), String(port))
        } else {
            portLabel = title
        }
        return [portLabel, detail].compactMap { $0 }.joined(separator: ", ")
    }
}
