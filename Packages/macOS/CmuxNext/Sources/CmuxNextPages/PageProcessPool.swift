public import WebKit

/// The process pool shared by cmux page views.
@MainActor
public struct PageProcessPool {
    public init() {}
    public static let shared = WKProcessPool()
}
