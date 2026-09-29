/// Decides how cmux answers Ghostty's clipboard confirmation callback.
///
/// Ghostty asks for confirmation in two cases: a paste its
/// `clipboard-paste-protection` flags as unsafe, and an OSC 52 clipboard read
/// under `clipboard-read = ask`. cmux approves both without asking unless
/// `terminal.confirmUnsafePaste` is on, and that setting only covers pastes.
public struct TerminalUnsafePasteConfirmationPolicy: Equatable, Sendable {
    /// How to answer one confirmation request.
    public enum Decision: Equatable, Sendable {
        /// Complete the request as confirmed, without asking.
        case approve
        /// Ask in a sheet attached to the terminal's window.
        case askInWindowSheet
        /// Complete the request with no text.
        case reject
    }

    /// The `terminal.confirmUnsafePaste` setting.
    public var confirmationEnabled: Bool

    /// The number of lines the sheet preview keeps.
    public var maximumPreviewLines: Int

    /// The number of characters the sheet preview keeps per line.
    public var maximumPreviewLineLength: Int

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - confirmationEnabled: The `terminal.confirmUnsafePaste` setting.
    ///   - maximumPreviewLines: The number of lines the preview keeps.
    ///   - maximumPreviewLineLength: The number of characters the preview
    ///     keeps per line.
    public init(
        confirmationEnabled: Bool,
        maximumPreviewLines: Int = 8,
        maximumPreviewLineLength: Int = 160
    ) {
        self.confirmationEnabled = confirmationEnabled
        self.maximumPreviewLines = max(1, maximumPreviewLines)
        self.maximumPreviewLineLength = max(1, maximumPreviewLineLength)
    }

    /// Returns how to answer a confirmation request.
    ///
    /// - Parameters:
    ///   - isPasteRequest: Whether Ghostty flagged a paste, as opposed to an
    ///     OSC 52 read.
    ///   - hasWindow: Whether the terminal view is in a window a sheet can
    ///     attach to.
    /// - Returns: The decision. A paste the user asked to confirm is rejected
    ///   when there is no window to ask in, rather than pasted unasked.
    public func decision(isPasteRequest: Bool, hasWindow: Bool) -> Decision {
        guard isPasteRequest, confirmationEnabled else { return .approve }
        return hasWindow ? .askInWindowSheet : .reject
    }

    /// A bounded excerpt of the pasted text for the confirmation sheet.
    ///
    /// Keeps at most ``maximumPreviewLines`` lines and
    /// ``maximumPreviewLineLength`` characters per line, marking each cut
    /// with an ellipsis, so a large paste cannot grow the sheet past the
    /// window.
    ///
    /// - Parameter text: The text waiting to be pasted.
    /// - Returns: The excerpt, with line breaks normalized to `\n`.
    public func preview(of text: String) -> String {
        let lines = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
        var kept = lines.prefix(maximumPreviewLines).map { line -> String in
            guard line.count > maximumPreviewLineLength else { return String(line) }
            return String(line.prefix(maximumPreviewLineLength)) + "…"
        }
        if lines.count > maximumPreviewLines {
            kept.append("…")
        }
        return kept.joined(separator: "\n")
    }
}
