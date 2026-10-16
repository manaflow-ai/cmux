@testable import CmuxSudoBroker
import Foundation

struct TestAppLauncher: SudoAppLaunching {
    private let onLaunch: @Sendable () throws -> Void

    init(onLaunch: @escaping @Sendable () throws -> Void = {}) {
        self.onLaunch = onLaunch
    }

    func launch(appBundleURL: URL) throws {
        try onLaunch()
    }
}
