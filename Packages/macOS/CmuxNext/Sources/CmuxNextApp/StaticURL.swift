import Foundation

/// Fixed URLs the app builds from literals. `URL(string:)` is optional, so a
/// literal goes through `url`, which never traps: a literal that did not
/// parse would become a file URL of the same text. StaticURLTests checks
/// that every case parses, so that fallback is never taken.
nonisolated enum StaticURL: String, CaseIterable {
    case feedback = "https://github.com/manaflow-ai/cmux/issues/new"
    case documentation = "https://cmux.com/docs"
    case blank = "about:blank"

    var url: URL { URL(string: rawValue) ?? URL(fileURLWithPath: rawValue) }
}
