public import Foundation

/// The localized, app-resolved format templates and fallbacks used to render a
/// ``CmuxConfigIssue`` as a command-palette row.
///
/// `String(localized:)` must resolve in the app bundle (it carries the
/// `command.cmuxConfig.issue.*` keys and their per-locale translations);
/// resolving inside this package would bind to the package bundle, silently
/// dropping the non-English variants. So the app resolves every template + the
/// schema-error fallback once and passes them across this seam, mirroring the
/// `ControlNotificationStrings` injection pattern. The package owns only the
/// `switch`-on-``CmuxConfigIssue/Kind`` selection and the `String(format:)`
/// argument ordering.
public struct CmuxConfigIssuePaletteStrings: Sendable, Equatable {
    /// `command.cmuxConfig.issue.schemaError.title` —
    /// "cmux.json Schema Error".
    public let schemaErrorTitle: String
    /// `command.cmuxConfig.issue.warning.title` —
    /// "cmux.json Configuration Warning".
    public let warningTitle: String
    /// `command.cmuxConfig.issue.subtitle` — "%@: %@" (path, detail).
    public let subtitleFormat: String
    /// `command.cmuxConfig.issue.schemaError.detail` — "%@" (message).
    public let schemaErrorDetailFormat: String
    /// `command.cmuxConfig.issue.schemaError.fallback` — "Invalid cmux.json".
    public let schemaErrorFallback: String
    /// `command.cmuxConfig.issue.newWorkspaceActionNotFound.detail` —
    /// "%@ references missing action '%@'" (settingName, commandName).
    public let newWorkspaceActionNotFoundDetailFormat: String
    /// `command.cmuxConfig.issue.newWorkspaceCommandNotFound.detail` —
    /// "%@ references missing command '%@'" (settingName, commandName).
    public let newWorkspaceCommandNotFoundDetailFormat: String
    /// `command.cmuxConfig.issue.newWorkspaceCommandRequiresWorkspace.detail` —
    /// "%@ '%@' must reference a workspace command" (settingName, commandName).
    public let newWorkspaceCommandRequiresWorkspaceDetailFormat: String

    /// Creates the localized palette-formatting bundle.
    ///
    /// - Parameters:
    ///   - schemaErrorTitle: The schema-error row title.
    ///   - warningTitle: The configuration-warning row title.
    ///   - subtitleFormat: The "path: detail" subtitle format.
    ///   - schemaErrorDetailFormat: The schema-error detail format.
    ///   - schemaErrorFallback: The schema-error message fallback.
    ///   - newWorkspaceActionNotFoundDetailFormat: The missing-action detail format.
    ///   - newWorkspaceCommandNotFoundDetailFormat: The missing-command detail format.
    ///   - newWorkspaceCommandRequiresWorkspaceDetailFormat: The requires-workspace detail format.
    public init(
        schemaErrorTitle: String,
        warningTitle: String,
        subtitleFormat: String,
        schemaErrorDetailFormat: String,
        schemaErrorFallback: String,
        newWorkspaceActionNotFoundDetailFormat: String,
        newWorkspaceCommandNotFoundDetailFormat: String,
        newWorkspaceCommandRequiresWorkspaceDetailFormat: String
    ) {
        self.schemaErrorTitle = schemaErrorTitle
        self.warningTitle = warningTitle
        self.subtitleFormat = subtitleFormat
        self.schemaErrorDetailFormat = schemaErrorDetailFormat
        self.schemaErrorFallback = schemaErrorFallback
        self.newWorkspaceActionNotFoundDetailFormat = newWorkspaceActionNotFoundDetailFormat
        self.newWorkspaceCommandNotFoundDetailFormat = newWorkspaceCommandNotFoundDetailFormat
        self.newWorkspaceCommandRequiresWorkspaceDetailFormat = newWorkspaceCommandRequiresWorkspaceDetailFormat
    }
}

extension CmuxConfigIssue {
    /// The command-palette row title for this issue.
    ///
    /// Schema errors get the schema-error title; every other kind gets the
    /// generic configuration-warning title.
    ///
    /// - Parameter strings: App-resolved localized titles.
    /// - Returns: The localized row title.
    public func paletteTitle(strings: CmuxConfigIssuePaletteStrings) -> String {
        switch kind {
        case .schemaError:
            return strings.schemaErrorTitle
        default:
            return strings.warningTitle
        }
    }

    /// The command-palette row detail string for this issue.
    ///
    /// Selects the per-kind detail format and fills it with `settingName`,
    /// `commandName`, or the schema `message` (falling back to
    /// ``CmuxConfigIssuePaletteStrings/schemaErrorFallback`` when absent).
    ///
    /// - Parameter strings: App-resolved localized detail formats + fallback.
    /// - Returns: The localized, unsanitized detail string.
    public func paletteDetail(strings: CmuxConfigIssuePaletteStrings) -> String {
        switch kind {
        case .schemaError:
            return String(
                format: strings.schemaErrorDetailFormat,
                message ?? strings.schemaErrorFallback
            )
        case .newWorkspaceActionNotFound:
            return String(
                format: strings.newWorkspaceActionNotFoundDetailFormat,
                settingName,
                commandName ?? ""
            )
        case .newWorkspaceCommandNotFound:
            return String(
                format: strings.newWorkspaceCommandNotFoundDetailFormat,
                settingName,
                commandName ?? ""
            )
        case .newWorkspaceCommandRequiresWorkspace:
            return String(
                format: strings.newWorkspaceCommandRequiresWorkspaceDetailFormat,
                settingName,
                commandName ?? ""
            )
        }
    }

    /// The command-palette row subtitle, built from a pre-sanitized path and
    /// pre-sanitized detail.
    ///
    /// The caller sanitizes both values before passing them in (the sanitizer
    /// lives in a higher package that this leaf cannot reach). When the detail
    /// is empty the path is returned alone; otherwise the two are joined by the
    /// "path: detail" subtitle format.
    ///
    /// - Parameters:
    ///   - sanitizedPath: The already-sanitized source path or setting name.
    ///   - sanitizedDetail: The already-sanitized detail string.
    ///   - subtitleFormat: The app-resolved "%@: %@" subtitle format.
    /// - Returns: The localized row subtitle.
    public func paletteSubtitle(
        sanitizedPath: String,
        sanitizedDetail: String,
        subtitleFormat: String
    ) -> String {
        guard !sanitizedDetail.isEmpty else { return sanitizedPath }
        return String(format: subtitleFormat, sanitizedPath, sanitizedDetail)
    }
}
