import Foundation

protocol SudoTouchIDSetupLaunching {
    /// Runs the authenticated setup script through a root-staged copy.
    func run(helper: SudoVerifiedHelper) throws -> Int32
}
