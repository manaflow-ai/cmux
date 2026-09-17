internal import CmuxTerminalBackend

@MainActor
struct BackendOnlyHostPublishedProjection {
    let authority: BackendOnlyProjectionDriverPublication
    let runtime: BackendOnlyProjectionRuntimeSnapshot?
}
