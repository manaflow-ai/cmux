import CmuxNextCompat
import Foundation

/// The Ghostty config's own `term`, when the person set one: new terminals honor it unless cmux.json's
/// `terminal.term` is set (``TerminalTermChoice``). Ghostty's default (`xterm-ghostty`) is not read: only a
/// `term = ...` line in the files the loaded config came from (the config files and their `config-file`
/// includes, in load order) counts; the last one wins and an empty value resets it. The config build reads
/// it on its loader lane (``GhosttyBuiltConfig/term``), never the main actor.
///
/// ```swift
/// GhosttyConfigTerm.term(inFiles: GhosttyRuntime.loadedFiles(configFile: path)) // "xterm-ghostty"
/// ```
nonisolated enum GhosttyConfigTerm {
    /// The `term` `paths` set, read in order; nil when none sets one.
    static func term(inFiles paths: [String]) -> String? {
        var term: String?
        for path in paths {
            guard let text = try? String(blockingContentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { continue }
            term = self.term(configText: text, after: term)
        }
        return term
    }

    /// `term` after the `term` lines of one config file's `text`.
    static func term(configText text: String, after term: String? = nil) -> String? {
        var result = term
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let key = pair.first, let rest = pair.last, key.trimmingCharacters(in: .whitespaces) == "term" else { continue }
            var value = rest.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            result = value.isEmpty ? nil : value
        }
        return result
    }
}
