public import Foundation

/// The camera and microphone a workspace's browser tabs capture, as its sidebar row shows
/// it: a red camera or microphone (Chrome's recording indicator) while any tab captures. A
/// click on it shows the tab that captures (`SidebarIntent.showCapturingTab`).
public nonisolated struct SidebarWorkspaceCapture: Hashable, Sendable {
    /// A tab reads the camera.
    public var camera: Bool
    /// A tab reads the microphone.
    public var microphone: Bool

    public init(camera: Bool, microphone: Bool) {
        self.camera = camera
        self.microphone = microphone
    }

    /// The row's mark for its tabs' marks (`nil`: the tab captures nothing): what any tab
    /// captures, together; nil when no tab captures.
    public static func merge(_ tabs: some Sequence<SidebarWorkspaceCapture?>) -> SidebarWorkspaceCapture? {
        var merged = SidebarWorkspaceCapture(camera: false, microphone: false)
        for tab in tabs {
            guard let tab else { continue }
            merged.camera = merged.camera || tab.camera
            merged.microphone = merged.microphone || tab.microphone
        }
        return merged.camera || merged.microphone ? merged : nil
    }
}
