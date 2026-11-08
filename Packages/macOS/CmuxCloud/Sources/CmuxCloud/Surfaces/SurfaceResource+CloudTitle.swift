import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceResource {
    public var cloudProcessDisplayTitle: String {
        let value = RemoteTerminalTitle(processTitle: title).processTitle
        return value.isEmpty ? String(localized: "cloudTree.terminal.untitled", defaultValue: "terminal") : value
    }

    public var cloudPoolDisplayTitle: String {
        let value = RemoteTerminalTitle(processTitle: title, viewNames: remoteViews?.map(\.name) ?? []).poolTitle
        return value.isEmpty ? cloudProcessDisplayTitle : value
    }
}
