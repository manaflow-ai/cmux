import Foundation

struct ForeignWindowLaunchConfiguration {
    let bundleIdentifier: String
    let preferredApplicationURL: URL?
    let fallbackApplicationURLs: [URL]
    let arguments: [String]
    let environment: [String: String]
    let directoriesToCreate: [URL]
}
