import Foundation

struct VSCodeServeWebLaunchOptions: Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}
