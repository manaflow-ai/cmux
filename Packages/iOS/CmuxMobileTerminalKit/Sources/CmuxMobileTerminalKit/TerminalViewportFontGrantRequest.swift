/// A destination font and the viewport capacity that must be acknowledged
/// before the font can render without clipping.
public struct TerminalViewportFontGrantRequest: Equatable, Sendable {
    /// The destination font size to apply after the viewport grant arrives.
    public let fontSize: Float32

    /// The maximum column count the destination font reported to the host.
    public let reportColumns: Int

    /// The row capacity reported to the host at the destination font size.
    public let reportRows: Int

    /// The effective row count that the host must preserve in its reply.
    public let sourceEffectiveRows: Int

    /// Creates a request for a destination font and its required viewport capacity.
    ///
    /// - Parameters:
    ///   - fontSize: The destination font size to apply after acknowledgement.
    ///   - reportColumns: The maximum safe column count at `fontSize`.
    ///   - reportRows: The row capacity sent in the viewport report.
    ///   - sourceEffectiveRows: The effective rows that the acknowledgement must preserve.
    public init(
        fontSize: Float32,
        reportColumns: Int,
        reportRows: Int,
        sourceEffectiveRows: Int
    ) {
        self.fontSize = fontSize
        self.reportColumns = reportColumns
        self.reportRows = reportRows
        self.sourceEffectiveRows = sourceEffectiveRows
    }
}
