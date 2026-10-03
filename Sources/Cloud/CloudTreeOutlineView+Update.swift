import CmuxSurfaceCatalogModel
import Foundation

extension CloudTreeOutlineView {
    /// A terminal rename needs a stable daemon tab placement. A terminal row
    /// with only a legacy workspace hint is not enough, because the same
    /// terminal can have zero or many tab placements.
    static func canRenameTerminal(resource: SurfaceResource, remoteView: SurfaceRemoteView?) -> Bool {
        remoteView != nil || resource.remoteViews?.isEmpty == false
    }

    /// A rename writes a name onto a daemon tab, so a row with no tab has
    /// nothing to write to and must not offer the verb.
    ///
    /// Another Mac is excluded even when the row does have a tab.
    /// `DeviceSurfaceProvider.renameRemoteTab` forwards to the host's terminal
    /// rename verb, which resolves the id with `requireTerminal: true`, so a
    /// browser or display rename there fails with "Terminal surface not found"
    /// after the row has already shown the new name optimistically. Renaming
    /// these on a device needs a host verb that is not terminal-only, which is
    /// its own change.
    ///
    /// There is no all-views fallback the way a terminal pool row has one. A
    /// display open in two workspaces reaches its pool row with no single view
    /// (`CloudTreeNodeBuilder` passes one only when there is exactly one), and
    /// that row is not offered the verb: writing a name to one of two tabs
    /// would be a guess. Naming every view at once is the terminal-only
    /// "Rename All Views" path and is not extended here.
    ///
    /// A port row is not offered the verb even though its placement can carry
    /// a tab. The row renders the forwarded link and falls back to the port
    /// number, never to a name, so a rename would write something no row
    /// shows. Naming ports is its own change, in the row first.
    static func canRenameRemoteView(resource: SurfaceResource, remoteView: SurfaceRemoteView?) -> Bool {
        remoteView != nil && !resource.id.machine.isDevice && !resource.id.isForwardedPort
    }
}

extension CloudTreeOutlineView.Coordinator {
    /// The representable and native tests enter through the same update boundary.
    func update(inputs: CloudTreeBuildInputs, now: Date = .now) {
        guard let nodes = nodeCache.nodes(ifChanged: inputs, now: now) else { return }
        apply(nodes: CloudTreeCreateActionBuilder.add(to: nodes))
    }
}
