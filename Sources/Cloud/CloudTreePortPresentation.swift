import CmuxSurfaceCatalogModel
import Foundation

/// Describes the in-app port action without presenting its routing address as a public link.
struct CloudTreePortPresentation {
    let resource: SurfaceResource
    let url: String?

    var title: String {
        guard let port = resource.id.forwardedPort ?? resource.port else { return resource.title }
        return ":\(port)"
    }

    var detail: String? {
        guard url != nil else { return resource.detail }
        return String(localized: "cloudTree.port.openInCmux", defaultValue: "Open in cmux")
    }

    var toolTip: String? {
        guard url != nil else { return resource.detail }
        return String(localized: "cloudTree.port.openInCmux.help", defaultValue: "Open in cmux. No VPN setup needed.")
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
