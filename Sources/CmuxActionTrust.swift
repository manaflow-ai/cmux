import CmuxWorkspaces
import Foundation

/// App composition-root accessor for the shared ``CmuxActionTrust`` store. The
/// store type and on-disk format live in `CmuxWorkspaces`; the app owns the
/// production store path (`Application Support/cmux/trusted-actions.json`) and
/// constructs the process-wide instance here. This `static let shared` is the
/// single construction point, kept app-side because the package must not own a
/// `static let shared` (de-singletonization rule).
extension CmuxActionTrust {
    static let shared = CmuxActionTrust(storePath: defaultStorePath())

    private static func defaultStorePath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("cmux")
        return appSupport.appendingPathComponent("trusted-actions.json").path
    }
}
