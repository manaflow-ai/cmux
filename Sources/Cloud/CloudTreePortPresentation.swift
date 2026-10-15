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

    /// Says where the row's link goes, so the private default is never a guess.
    var toolTip: String? {
        let privacy = String(
            localized: "cloudTree.port.privateToolTip",
            defaultValue: "Private: opens through your cmux VPN only. Use Share… to publish it."
        )
        return [resource.detail, privacy].compactMap { $0 }.joined(separator: "\n")
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

    /// `:3000 · vivid-newt`: a port preview's tab title until its page reports one.
    /// The same `:<port>` the Ports row shows, so the tab and the row read alike.
    static func previewTabTitle(port: Int, machineLabel: String?) -> String {
        let label = machineLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty else { return ":\(port)" }
        return String(
            format: String(localized: "cloudTree.port.previewTabTitle", defaultValue: ":%1$@ \u{00B7} %2$@"),
            String(port),
            label
        )
    }

    /// The disabled first line of a port's menu: who can reach it right now.
    /// `nil` sharing means publications have not been read yet.
    static func sharingStatus(_ sharing: CloudPortSharing?) -> String {
        switch sharing {
        case nil, .unshared?:
            return String(localized: "cloudTree.port.sharing.private", defaultValue: "Private \u{2014} only you, through your cmux VPN")
        case .personal?:
            return String(localized: "cloudTree.port.sharing.personal", defaultValue: "Published for you \u{2014} sign-in required")
        case .team?:
            return String(localized: "cloudTree.port.sharing.team", defaultValue: "Shared with your team \u{2014} sign-in required")
        case .public?:
            return String(localized: "cloudTree.port.sharing.public", defaultValue: "Public \u{2014} anyone with the link")
        }
    }
}
