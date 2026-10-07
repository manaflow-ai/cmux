import Foundation
public import UniformTypeIdentifiers

/// Something cmux can be the macOS default for. macOS has a default web
/// browser but no "default terminal"; the terminal claims are the URL
/// schemes and file types Terminal itself handles.
public nonisolated enum DefaultHandlerClaim: String, CaseIterable, Sendable, Identifiable {
    /// `http`, `https` (and HTML files, which follow the browser choice).
    case webBrowser
    /// `ssh://` links.
    case ssh
    /// `x-man-page://` links (Help Viewer and apps open man pages this way).
    case manPage
    /// `.command`, `.tool`, `.sh`, `.zsh` and `.bash` files opened from Finder.
    case shellScripts

    public var id: String { rawValue }

    public var schemes: [String] {
        switch self {
        case .webBrowser: ["http", "https"]
        case .ssh: ["ssh"]
        case .manPage: ["x-man-page"]
        case .shellScripts: []
        }
    }

    public var contentTypes: [UTType] {
        switch self {
        case .shellScripts:
            [UTType("com.apple.terminal.shell-script"), .shellScript, UTType("public.zsh-script"), UTType("public.bash-script")].compactMap { $0 }
        default: []
        }
    }

    public static let terminalClaims: [DefaultHandlerClaim] = [.ssh, .manPage, .shellScripts]
}

/// The macOS default-app registry, behind a protocol so tests and test
/// launches (`CMUX_NEXT_MOCK_DEFAULT_HANDLERS=1`) never change the real
/// default browser.
@MainActor
public protocol DefaultAppRegistering: AnyObject {
    /// The app that opens `scheme` URLs now.
    func handler(forScheme scheme: String) -> URL?
    func handler(forContentType type: UTType) -> URL?
    /// Makes cmux the handler. For `http`/`https` macOS first asks the user
    /// to confirm; a refusal throws.
    func setDefault(forScheme scheme: String) async throws
    func setDefault(forContentType type: UTType) async throws
    /// This app's bundle (tagged builds compare by bundle id).
    var appBundleURL: URL { get }
}

extension DefaultAppRegistering {
    /// Whether every scheme and type of `claim` opens in this app.
    public func isClaimed(_ claim: DefaultHandlerClaim) -> Bool {
        let handlers = claim.schemes.map { handler(forScheme: $0) } + claim.contentTypes.map { handler(forContentType: $0) }
        return !handlers.isEmpty && handlers.allSatisfy { $0.map(isThisApp) ?? false }
    }

    public func claim(_ claim: DefaultHandlerClaim) async throws {
        for scheme in claim.schemes { try await setDefault(forScheme: scheme) }
        for type in claim.contentTypes { try await setDefault(forContentType: type) }
    }

    func isThisApp(_ url: URL) -> Bool {
        if url.standardizedFileURL == appBundleURL.standardizedFileURL { return true }
        guard let id = Bundle(url: url)?.bundleIdentifier else { return false }
        return id == Bundle(url: appBundleURL)?.bundleIdentifier
    }
}
