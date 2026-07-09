import Foundation

/// One TUI pane an extension contributes to the Dock: a title plus the argv
/// to launch, mirroring herdr's `[[panes]]` manifest section.
public struct DockExtensionPane: Equatable, Sendable {
    /// Pane identifier, unique within its extension. Same charset as extension
    /// ids minus dots (letters, digits, `_`, `:`, `-`), so the qualified
    /// `<extensionId>.<paneId>` form splits unambiguously on the last dot.
    public let id: String

    /// Human-readable pane title shown on the Dock tab and in launchers.
    public let title: String

    /// The command to launch, as an argv array. The first element is the
    /// program; cmux shell-quotes the array and runs it through the user's
    /// login shell (for PATH/toolchain resolution), with the extension root as
    /// the working directory.
    public let command: [String]

    /// Extra environment variables for the pane process, merged under the
    /// `CMUX_EXTENSION_*` context variables cmux injects (cmux's values win on
    /// conflict).
    public let env: [String: String]

    /// Optional working directory relative to the extension root. Absolute
    /// paths and `..` traversal are rejected at parse time.
    public let cwd: String?

    /// Optional platform allowlist for this pane; `nil` means every platform.
    public let platforms: [String]?

    /// Reserved placement hint. Only `"dock"` is meaningful in v1; other
    /// values parse with a warning so future manifests stay installable.
    public let placement: String?

    /// The qualified `<extensionId>.<paneId>` identifier used by launchers and
    /// the `CMUX_DOCK_CONTROL_ID` environment variable.
    public static func qualifiedId(extensionId: String, paneId: String) -> String {
        "\(extensionId).\(paneId)"
    }

    /// Splits a qualified pane id on its last dot (pane ids cannot contain
    /// dots, extension ids can). Returns `nil` when either side is empty.
    public static func splitQualifiedId(_ qualifiedId: String) -> (extensionId: String, paneId: String)? {
        guard let separator = qualifiedId.lastIndex(of: "."),
              separator != qualifiedId.startIndex else { return nil }
        let paneStart = qualifiedId.index(after: separator)
        guard paneStart != qualifiedId.endIndex else { return nil }
        return (String(qualifiedId[..<separator]), String(qualifiedId[paneStart...]))
    }

    /// Memberwise initializer, primarily for tests; production panes come from
    /// manifest parsing.
    public init(
        id: String,
        title: String,
        command: [String],
        env: [String: String] = [:],
        cwd: String? = nil,
        platforms: [String]? = nil,
        placement: String? = nil
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.env = env
        self.cwd = cwd
        self.platforms = platforms
        self.placement = placement
    }
}
