import CmuxCore
import Foundation

extension SurfaceResource {
    var cloudProcessDisplayTitle: String {
        let value = RemoteTerminalTitle(processTitle: title).processTitle
        return value.isEmpty ? String(localized: "cloudTree.terminal.untitled", defaultValue: "terminal") : value
    }

    var cloudPoolDisplayTitle: String {
        let value = RemoteTerminalTitle(processTitle: title, viewNames: remoteViews?.map(\.name) ?? []).poolTitle
        return value.isEmpty ? cloudProcessDisplayTitle : value
    }
}
