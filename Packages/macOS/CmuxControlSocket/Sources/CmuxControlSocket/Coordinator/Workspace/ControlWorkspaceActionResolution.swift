import Foundation

/// The outcome of validating a `workspace.action` request, before the app
/// applies any live `TabManager` mutation.
///
/// `v2WorkspaceAction` resolves the target workspace (still app-side, since that
/// reads live state) and then consults this type for the action's validity, the
/// title/description trimming rules, and the color name→hex resolution. Each
/// failure case documents the legacy `code`/`message`/`data` the app echoes back
/// so the wire contract stays byte-identical; the app owns turning these into the
/// Foundation `V2CallResult` payload (and supplies the `supported_actions` list
/// from ``supportedActions`` on the `unknownAction` failure).
public enum ControlWorkspaceActionResolution: Sendable, Equatable {
    /// The action key was not recognized (legacy `invalid_params` / "Unknown
    /// workspace action", `data` carries `action` + `supported_actions`).
    case unknownAction
    /// `rename` was missing a non-blank title (legacy `invalid_params` / "Missing
    /// or invalid title", no `data`).
    case missingTitle
    /// `set_description` was missing a non-blank description (legacy
    /// `invalid_params` / "Missing or invalid description", no `data`).
    case missingDescription
    /// `set_color` was missing a non-blank color (legacy `invalid_params` /
    /// "Missing or invalid color", no `data`).
    case missingColor
    /// `set_color` had a color that matched no palette name and was not a valid
    /// hex value (legacy `invalid_params` / "Invalid color. Use a hex value
    /// (#RRGGBB) or a named color.", `data` carries `named_colors`).
    case invalidColor(namedColors: [String])
    /// The request validated; carries the plan the app applies.
    case planned(ControlWorkspaceActionPlan)

    /// The supported `workspace.action` keys, in the legacy order the body
    /// reports them in the `supported_actions` error payload.
    public static let supportedActions: [String] = [
        "pin", "unpin", "rename", "clear_name",
        "set_description", "clear_description",
        "move_up", "move_down", "move_top",
        "close_others", "close_above", "close_below",
        "mark_read", "mark_unread",
        "set_color", "clear_color"
    ]

    /// Validates a `workspace.action` request and produces its plan or failure.
    ///
    /// - Parameters:
    ///   - action: The normalized action key (already lowercased with hyphens
    ///     mapped to underscores by the app's `v2ActionKey`).
    ///   - title: The raw `title` param, for `rename`.
    ///   - description: The raw `description` param, for `set_description` (stored
    ///     untrimmed).
    ///   - color: The raw `color` param, for `set_color`.
    ///   - palette: The effective palette snapshot, for resolving a named
    ///     `set_color` value (the app passes it only for `set_color`).
    /// - Returns: ``planned(_:)`` with the validated plan, or a failure case.
    public static func resolve(
        action: String,
        title: String?,
        description: String?,
        color: String?,
        palette: [ControlWorkspaceColorPaletteEntry]
    ) -> ControlWorkspaceActionResolution {
        switch action {
        case "pin":
            return .planned(.pin)
        case "unpin":
            return .planned(.unpin)
        case "rename":
            guard let titleRaw = title,
                  !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missingTitle
            }
            return .planned(.rename(title: titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)))
        case "clear_name":
            return .planned(.clearName)
        case "set_description":
            guard let descriptionRaw = description,
                  !descriptionRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missingDescription
            }
            return .planned(.setDescription(description: descriptionRaw))
        case "clear_description":
            return .planned(.clearDescription)
        case "move_up":
            return .planned(.moveUp)
        case "move_down":
            return .planned(.moveDown)
        case "move_top":
            return .planned(.moveTop)
        case "close_others":
            return .planned(.closeOthers)
        case "close_above":
            return .planned(.closeAbove)
        case "close_below":
            return .planned(.closeBelow)
        case "mark_read":
            return .planned(.markRead)
        case "mark_unread":
            return .planned(.markUnread)
        case "set_color":
            guard let colorRaw = color,
                  !colorRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missingColor
            }
            let colorInput = colorRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Resolve named colors from the effective palette, including
            // file-defined additions, then fall back to a hex literal.
            if let entry = palette.first(where: {
                $0.name.caseInsensitiveCompare(colorInput) == .orderedSame
            }) {
                return .planned(.setColor(hex: entry.hex))
            } else if let normalized = Self.normalizedHex(colorInput) {
                return .planned(.setColor(hex: normalized))
            } else {
                return .invalidColor(namedColors: palette.map(\.name))
            }
        case "clear_color":
            return .planned(.clearColor)
        default:
            return .unknownAction
        }
    }

    /// Normalizes a hex color string to `"#RRGGBB"` uppercased, or `nil` when the
    /// input is not a 6-digit hex value.
    ///
    /// A faithful copy of the app's `WorkspaceTabColorSettings.normalizedHex` so
    /// the resolution stays self-contained (the package does not depend on the
    /// app-side color settings).
    private static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else { return nil }
        guard UInt64(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }
}
