/// A POSIX character class inside a glob bracket, as the C locale defines it.
enum GlobCharacterClass: String, Sendable, CaseIterable {
    case alnum, alpha, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit

    /// Whether `scalar` belongs to the class. Non-ASCII scalars use their Unicode properties.
    func contains(_ scalar: UInt32) -> Bool {
        guard let character = Unicode.Scalar(scalar) else { return false }
        let properties = character.properties
        let isASCII = scalar <= 127
        let isUpper = isASCII ? (0x41...0x5A).contains(scalar) : properties.isUppercase
        let isLower = isASCII ? (0x61...0x7A).contains(scalar) : properties.isLowercase
        let isAlpha = isASCII ? isUpper || isLower : properties.isAlphabetic
        let isDigit = (0x30...0x39).contains(scalar)
        let isControl = scalar < 0x20 || scalar == 0x7F
        let isSpace = isASCII ? scalar == 0x20 || (0x09...0x0D).contains(scalar) : properties.isWhitespace
        let isGraph = isASCII ? (0x21...0x7E).contains(scalar) : !properties.isWhitespace && !isControl
        switch self {
        case .alnum: return isAlpha || isDigit
        case .alpha: return isAlpha
        case .blank: return scalar == 0x20 || scalar == 0x09
        case .cntrl: return isControl
        case .digit: return isDigit
        case .graph: return isGraph
        case .lower: return isLower
        case .print: return isGraph || scalar == 0x20
        case .punct: return isGraph && !isAlpha && !isDigit
        case .space: return isSpace
        case .upper: return isUpper
        case .xdigit: return isDigit || (0x41...0x46).contains(scalar) || (0x61...0x66).contains(scalar)
        }
    }
}
