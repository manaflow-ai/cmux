public import Foundation

@MainActor
public enum BrowserErrorPageRetry {
    case urlOnly
    case request(URLRequest)
    case disabled
}
