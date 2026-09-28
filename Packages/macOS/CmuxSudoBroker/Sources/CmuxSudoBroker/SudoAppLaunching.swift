import Foundation

protocol SudoAppLaunching: Sendable {
    func launch(appBundleURL: URL) throws
}
