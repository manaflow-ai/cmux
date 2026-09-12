import Foundation

/// Resolves symlinked configuration URLs without owning filesystem state.
struct JSONConfigFilePathResolver: Sendable {
    private let symbolicLinkDestination: @Sendable (String) -> String?

    init(
        symbolicLinkDestination: @escaping @Sendable (String) -> String? = { path in
            try? FileManager().destinationOfSymbolicLink(atPath: path)
        }
    ) {
        self.symbolicLinkDestination = symbolicLinkDestination
    }

    func resolvedURL(for url: URL) -> URL {
        guard let destination = symbolicLinkDestination(url.path) else { return url }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}
