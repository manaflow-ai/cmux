import Foundation

@MainActor
enum BrowserErrorPageRetry {
    case urlOnly
    case request(URLRequest)
    case disabled
}
