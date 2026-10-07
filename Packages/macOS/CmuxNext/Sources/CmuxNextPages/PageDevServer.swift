public import Foundation

/// The Vite dev server every React page loads from in Debug and tagged builds
/// (`CMUX_NEXT_PAGES_DEV_URL`). Not wired yet.
public nonisolated struct PageDevServer: Sendable, Equatable {
    public static let variable = "CMUX_NEXT_PAGES_DEV_URL"
    public let root: URL

    public static func resolve(environment: [String: String], allowsDevServer: Bool) -> PageDevServer? { nil }

    func url(for request: URL, page: PageDescriptor) -> URL? { nil }

    func csp(for page: PageDescriptor) -> PageCSP { page.csp }
}
