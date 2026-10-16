/// Turns a PostScript font name (`FiraCode-Retina`) into the family name Ghostty expects (`Fira Code`).
///
/// iTerm2 and Terminal store PostScript names; Ghostty's `font-family` takes a
/// family. Injected so tests don't depend on the fonts installed on the machine.
public protocol FontFamilyResolving: Sendable {
    /// The family name of an installed font, or `nil` when no font has this PostScript name.
    ///
    /// - Parameter postScriptName: The PostScript name the source stored.
    func familyName(forPostScriptName postScriptName: String) -> String?
}
