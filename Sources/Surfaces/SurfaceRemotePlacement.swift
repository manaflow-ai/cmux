/// The confirmed daemon tab behind a local pane. It is independent of local geometry.
struct SurfaceRemotePlacement: Equatable, Sendable {
    let workspaceID: String
    let tabID: String
    var cursor: CloudVMCursor? = nil
}
