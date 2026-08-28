public import Foundation

/// Why a web-backed sidebar file cannot be rendered.
///
/// A `.url` file that names nothing usable is the failure people actually hit: the file exists, the
/// sidebar appears in the picker, and the pane comes up blank. `cmux sidebar validate` exists to
/// answer that before the user has to guess, so the reason has to survive as a value rather than
/// collapsing into "invalid".
public enum CustomSidebarWebSourceProblem: Equatable, Sendable {
    /// The file could not be read as UTF-8 text.
    case unreadable
    /// The file is larger than a shortcut file has any reason to be, so it was not read.
    ///
    /// Its own problem rather than ``unreadable`` because the fix is different and obvious once
    /// said: the file that landed at this name is not a shortcut file.
    case tooLarge
    /// The file held no line that parsed as a URL at all.
    case noURL
    /// The file named a URL, but not one this sidebar may load.
    ///
    /// Carries the offending scheme when there was one, so the message can say `file` rather than
    /// leaving the author to work out which of several lines was rejected.
    case unsupportedScheme(String?)
    /// The file named an `http`/`https` URL with no host, so there is nothing to fetch.
    ///
    /// Distinct from ``unsupportedScheme(_:)`` because the fix is different: the scheme is right and
    /// the address is missing.
    case missingHost

    /// Diagnoses a `.url` file, returning `nil` when it names a loadable page.
    ///
    /// Mirrors ``CustomSidebarWebSource/remoteURL(fromURLFile:)`` exactly — that method answers
    /// "which URL", this one answers "why not" — so validation can never approve a file the renderer
    /// then refuses, or vice versa.
    ///
    /// - Parameter fileURL: The `.url` file to diagnose.
    /// - Returns: The problem, or `nil` when the file is usable.
    public static func diagnose(urlFile fileURL: URL) -> CustomSidebarWebSourceProblem? {
        let lines: [String]
        switch CustomSidebarURLFileReader.read(fileURL: fileURL) {
        case .unreadable: return .unreadable
        case .tooLarge: return .tooLarge
        case let .lines(read): lines = read
        }
        var rejectedScheme: String?
        var sawHostlessWebURL = false
        var sawCandidate = false
        for candidate in lines {
            guard let url = URL(string: candidate) else { continue }
            sawCandidate = true
            if CustomSidebarWebSource.isLoadable(url) { return nil }
            guard let scheme = url.scheme?.lowercased() else { continue }
            if scheme == "http" || scheme == "https" {
                sawHostlessWebURL = true
            } else if rejectedScheme == nil {
                rejectedScheme = scheme
            }
        }
        // A right-scheme-wrong-address line is the more useful thing to report, since the author was
        // clearly trying to name a page.
        if sawHostlessWebURL { return .missingHost }
        if let rejectedScheme { return .unsupportedScheme(rejectedScheme) }
        return sawCandidate ? .unsupportedScheme(nil) : .noURL
    }
}
