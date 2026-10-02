import CmuxSurfaceCatalogModel
import Foundation

/// Describes the port identity without adding an inline open action.
struct CloudTreePortPresentation {
    let resource: SurfaceResource

    var title: String {
        guard let port = resource.id.forwardedPort ?? resource.port else { return resource.title }
        return ":\(port)"
    }

    var detail: String? {
        resource.detail
    }

    var toolTip: String? {
        String(localized: "cloudTree.port.openInCmuxHelp", defaultValue: "Open in cmux. No VPN setup needed.")
    }

    var accessibilityLabel: String {
        let portLabel: String
        if let port = resource.id.forwardedPort ?? resource.port {
            portLabel = String(format: String(localized: "cloudTree.port.title", defaultValue: "Port %@"), String(port))
        } else {
            portLabel = title
        }
        let openAction = String(localized: "fileExplorer.contextMenu.openInCmux", defaultValue: "Open in cmux")
        return [portLabel, openAction].joined(separator: ", ")
    }
}
