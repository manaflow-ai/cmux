public import Foundation

/// The source of a cookie import as the CLI names it: `<browser>[:<profile>]`
/// (`chrome`, `arc:Work`, `brave:Profile 2`, `safari`, `firefox:default-release`).
///
/// The browser matches a registry id or its display name, ignoring case,
/// spaces and punctuation (`chrome`, `Google Chrome`, `edge`, `helium`). The
/// profile matches a profile's folder name or the name the browser shows; with
/// none, the browser's `Default` profile (else its first one) is used.
public struct CookieSourceQuery: Sendable, Equatable {
    public var browser: String
    public var profile: String?

    /// Why a query names no profile on this Mac.
    public enum Failure: Error, Equatable, Sendable {
        /// The value is blank.
        case empty
        /// No installed browser matches `browser`; `known` lists the ones found.
        case unknownBrowser(String, known: [String])
        /// The browser has no profile named `profile`; `known` lists its profiles.
        case unknownProfile(browser: String, profile: String, known: [String])
        /// The browser keeps its data in a store cmux does not read (Orion, Tor).
        case unsupported(String)
    }

    /// - Parameter text: `<browser>[:<profile>]`; the profile may contain colons.
    public init(_ text: String) throws(Failure) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        if let colon = trimmed.firstIndex(of: ":") {
            browser = String(trimmed.prefix(upTo: colon)).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed.suffix(from: colon).dropFirst()).trimmingCharacters(in: .whitespaces)
            profile = rest.isEmpty ? nil : rest
        } else {
            browser = trimmed
            profile = nil
        }
        guard !browser.isEmpty else { throw .empty }
    }

    /// The source profile this query names among `sources` (the detector's result).
    public func resolve(in sources: [BrowserSource]) throws(Failure) -> BrowserSourceProfile {
        let wanted = Self.key(browser)
        guard let source = sources.first(where: { Self.key($0.browser.rawValue) == wanted })
                ?? sources.first(where: { Self.key($0.browser.displayName) == wanted }) else {
            throw .unknownBrowser(browser, known: sources.map(\.browser.rawValue))
        }
        let family = source.browser.family
        guard !family.isPrivateStore, !source.browser.refusesSessionData else { throw .unsupported(source.browser.displayName) }
        guard let profile else {
            if let first = source.profiles.first(where: { $0.directoryName == "Default" }) ?? source.profiles.first { return first }
            throw .unknownProfile(browser: source.browser.rawValue, profile: "Default", known: [])
        }
        let key = Self.key(profile)
        let match = source.profiles.first { $0.directoryName == profile }
            ?? source.profiles.first { Self.key($0.directoryName) == key || Self.key($0.displayName) == key }
            // Firefox folders are `Profiles/abcd.default-release`: its suffix names it too.
            ?? source.profiles.first { Self.key($0.directoryName).hasSuffix(key) }
        guard let match else {
            throw .unknownProfile(browser: source.browser.rawValue, profile: profile,
                                  known: source.profiles.map { $0.displayName.isEmpty ? $0.directoryName : $0.displayName })
        }
        return match
    }

    /// Lowercased letters and digits only, so `Google Chrome`, `google-chrome` and `googlechrome` match.
    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
