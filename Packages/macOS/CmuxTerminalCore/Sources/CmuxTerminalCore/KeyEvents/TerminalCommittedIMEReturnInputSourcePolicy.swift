import Foundation

/// Decides whether the Return that just committed an IME composition should
/// also be forwarded to the surface as a key press.
///
/// Korean IME: Enter commits the syllable AND executes the command (single step).
/// Japanese/Chinese IME: Enter only confirms the conversion; a second Enter executes.
/// So the extra Return is only forwarded for Korean input sources. Apple's Korean
/// sources carry "korean" in their ID; third-party ones (e.g. Gureum:
/// "org.youknowone.inputmethod.Gureum.han2") don't, so a source whose declared
/// primary language (`kTISPropertyInputSourceLanguages`) is Korean also qualifies.
public struct TerminalCommittedIMEReturnInputSourcePolicy: Sendable {
    /// Creates the committed-IME-Return policy.
    public init() {}

    /// Returns whether the committed-composition Return should be forwarded for
    /// the given input source.
    ///
    /// - Parameters:
    ///   - sourceId: `kTISPropertyInputSourceID` of the current input source, or
    ///     `nil` when it could not be read. A missing ID never qualifies.
    ///   - languages: `kTISPropertyInputSourceLanguages` of the current input
    ///     source, primary language first. Only the primary language is consulted.
    public func shouldForwardReturn(sourceId: String?, languages: [String]) -> Bool {
        guard let sourceId else { return false }
        if sourceId.range(of: "korean", options: .caseInsensitive) != nil { return true }
        return languages.first == "ko"
    }
}
