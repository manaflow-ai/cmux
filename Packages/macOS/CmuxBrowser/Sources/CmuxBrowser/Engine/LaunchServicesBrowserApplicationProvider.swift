public import AppKit

/// Reads default URL handlers and installed Chromium applications through LaunchServices.
@MainActor
public final class LaunchServicesBrowserApplicationProvider: BrowserApplicationProviding {
    private let workspace: NSWorkspace

    /// Creates a LaunchServices-backed provider.
    ///
    /// - Parameter workspace: The workspace used for URL-handler and application lookup.
    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    /// Returns the applications LaunchServices selects for HTTPS and HTTP.
    public func defaultBrowserApplications() -> [BrowserApplication] {
        let representativeURLs = [
            URL(string: "https://cmux.invalid/default-browser")!,
            URL(string: "http://cmux.invalid/default-browser")!,
        ]
        return deduplicatedApplications(representativeURLs.compactMap { url in
            workspace.urlForApplication(toOpen: url).flatMap(application(at:))
        })
    }

    /// Returns installed Chromium-family applications in stable preference order.
    public func installedChromiumApplications() -> [BrowserApplication] {
        let bundleIdentifiers = BrowserImportBrowserDescriptor.allBrowserDescriptors
            .filter { $0.family == .chromium }
            .flatMap(\.bundleIdentifiers)
        return deduplicatedApplications(bundleIdentifiers.compactMap { bundleIdentifier in
            workspace.urlForApplication(withBundleIdentifier: bundleIdentifier).flatMap(application(at:))
        })
    }

    private func application(at bundleURL: URL) -> BrowserApplication? {
        guard let bundle = Bundle(url: bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              let executableURL = bundle.executableURL else {
            return nil
        }
        return BrowserApplication(
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            executableURL: executableURL
        )
    }

    private func deduplicatedApplications(_ applications: [BrowserApplication]) -> [BrowserApplication] {
        var seen = Set<String>()
        return applications.filter { application in
            seen.insert(application.bundleIdentifier.lowercased()).inserted
        }
    }
}
