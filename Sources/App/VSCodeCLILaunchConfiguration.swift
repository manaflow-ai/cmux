import Foundation

struct VSCodeCLILaunchConfiguration {
    let executableURL: URL
    let argumentsPrefix: [String]
    let environment: [String: String]
    let launcherKind: VSCodeServeWebLauncherKind
}
