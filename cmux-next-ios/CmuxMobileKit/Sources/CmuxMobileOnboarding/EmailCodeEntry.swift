import CmuxMobileDesign

/// What the email sign-in code field accepts: the codes Stack Auth sends.
///
/// The emailed code is six ASCII letters and digits (`FWT88N`), so the field
/// takes letters and shows a keyboard with letters. The email step verifies as
/// soon as ``length`` characters are in.
struct EmailCodeEntry: Equatable, Sendable {
    /// The accepted characters; they also pick the keyboard.
    let characters: CodeEntryCharacters = .alphanumeric
    /// The number of characters in an emailed code.
    let length = 6

    /// Normalizes typed, pasted or autofilled text to the code the field shows.
    /// - Parameter raw: The field text.
    /// - Returns: At most ``length`` accepted characters, letters uppercase.
    func normalized(_ raw: String) -> String {
        characters.normalized(raw, length: length)
    }

    /// Whether `code` is complete, so the step verifies it.
    /// - Parameter code: A normalized code.
    /// - Returns: `true` when it has ``length`` characters.
    func isComplete(_ code: String) -> Bool {
        code.count == length
    }
}
