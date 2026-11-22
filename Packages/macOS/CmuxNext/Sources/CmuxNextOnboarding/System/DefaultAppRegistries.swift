import AppKit
public import Foundation
public import UniformTypeIdentifiers

/// The real registry: `NSWorkspace.setDefaultApplication(at:...)`, which
/// shows macOS's own confirmation for the web browser.
public final class SystemDefaultApps: DefaultAppRegistering {
    public let appBundleURL: URL

    public init(appBundleURL: URL = Bundle.main.bundleURL) {
        self.appBundleURL = appBundleURL
    }

    public func handler(forScheme scheme: String) -> URL? {
        guard let probe = URL(string: "\(scheme)://example") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    public func handler(forContentType type: UTType) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    public func setDefault(forScheme scheme: String) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: appBundleURL, toOpenURLsWithScheme: scheme)
    }

    public func setDefault(forContentType type: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: appBundleURL, toOpen: type)
    }
}

/// A registry in memory: records every change and never calls macOS. Used
/// by tests and by test launches with `CMUX_NEXT_MOCK_DEFAULT_HANDLERS=1`.
public final class RecordingDefaultApps: DefaultAppRegistering {
    public static let environmentKey = "CMUX_NEXT_MOCK_DEFAULT_HANDLERS"

    public let appBundleURL: URL
    public private(set) var schemes: [String: URL]
    public private(set) var types: [String: URL] = [:]
    /// Every change, in order ("scheme:http", "type:public.shell-script").
    public private(set) var log: [String] = []
    /// Schemes whose change the "user" refuses (tests of the refusal path).
    public var refusedSchemes: Set<String> = []

    public init(appBundleURL: URL = Bundle.main.bundleURL, schemes: [String: URL] = [:]) {
        self.appBundleURL = appBundleURL
        self.schemes = schemes
    }

    public func handler(forScheme scheme: String) -> URL? { schemes[scheme] }
    public func handler(forContentType type: UTType) -> URL? { types[type.identifier] }

    public func setDefault(forScheme scheme: String) async throws {
        guard !refusedSchemes.contains(scheme) else { throw CocoaError(.userCancelled) }
        schemes[scheme] = appBundleURL
        log.append("scheme:\(scheme)")
    }

    public func setDefault(forContentType type: UTType) async throws {
        types[type.identifier] = appBundleURL
        log.append("type:\(type.identifier)")
    }
}
