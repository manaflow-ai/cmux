/// A color named by an SGR escape sequence, before it is resolved against a
/// terminal palette.
public enum ANSIArtColor: Hashable, Sendable {
    /// A palette index, 0...255: 0...15 are the themeable base colors
    /// (`30`-`37`, `90`-`97` and their backgrounds), 16...255 the xterm
    /// color cube and gray ramp (`38;5;n`).
    case indexed(Int)
    /// A direct 24-bit color (`38;2;r;g;b`).
    case rgb(ANSIArtRGB)
}
