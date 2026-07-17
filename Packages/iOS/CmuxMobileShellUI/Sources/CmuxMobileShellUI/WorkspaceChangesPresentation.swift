import CmuxMobileDiff
import CmuxMobileRPC

/// Value request consumed by the workspace detail's single Changes presentation path.
struct WorkspaceChangesPresentation: Equatable {
    /// Optional changed file to reveal after summary loading.
    let scrollToPath: String?
    /// Initial Git comparison strategy for this entry point.
    let baseSpec: MobileChangesBaseSpec
}
