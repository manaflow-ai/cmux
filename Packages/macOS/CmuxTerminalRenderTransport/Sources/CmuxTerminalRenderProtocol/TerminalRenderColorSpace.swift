/// Color-space semantics attached to a renderer frame.
public enum TerminalRenderColorSpace: UInt32, CaseIterable, Sendable {
    /// Standard RGB using the sRGB transfer function.
    case sRGB = 1

    /// Display P3 using its standard transfer function.
    case displayP3 = 2

    /// Extended linear sRGB for high-dynamic-range composition.
    case extendedLinearSRGB = 3
}
