import Foundation

extension String {
    func clippedToRenderGridColumns(_ columns: Int) -> String {
        var occupiedColumns = 0
        var clipped = ""
        for character in self {
            let width = character.renderGridEstimatedCellWidth
            guard occupiedColumns + width <= columns else { break }
            clipped.append(character)
            occupiedColumns += width
        }
        return clipped
    }

    var renderGridEstimatedCellWidth: Int {
        reduce(0) { width, character in
            width + character.renderGridEstimatedCellWidth
        }
    }
}

extension MobileTerminalRenderGridFrame.RowSpan {
    var hasWidthSensitiveScalars: Bool {
        text.unicodeScalars.contains { $0.isRenderGridWidthSensitiveScalar }
    }

    var gridCellWidth: Int {
        cellWidth ?? max(1, text.renderGridEstimatedCellWidth)
    }
}

extension Character {
    var renderGridEstimatedCellWidth: Int {
        let scalars = unicodeScalars
        guard scalars.contains(where: { !$0.isRenderGridZeroWidthScalar }) else {
            return 0
        }
        if scalars.contains(where: { $0.isRenderGridWideScalar })
            || scalars.contains(where: { $0.isRenderGridEmojiPresentationScalar }) {
            return 2
        }
        return 1
    }

    var canExpandForAmbiguousRenderGridWidth: Bool {
        unicodeScalars.contains { $0.isRenderGridAmbiguousWidthScalar }
    }
}

extension UnicodeScalar {
    fileprivate var isRenderGridWidthSensitiveScalar: Bool {
        isRenderGridZeroWidthScalar
            || isRenderGridWideScalar
            || isRenderGridEmojiPresentationScalar
            || isRenderGridAmbiguousWidthScalar
    }

    var isRenderGridZeroWidthScalar: Bool {
        switch value {
        case 0x0300...0x036F,
             0x061C,
             0x1AB0...0x1AFF,
             0x1DC0...0x1DFF,
             0x180B...0x180F,
             0x200B...0x200F,
             0x20D0...0x20FF,
             0x202A...0x202E,
             0x2060...0x206F,
             0xFE00...0xFE0F,
             0xFEFF,
             0xFE20...0xFE2F,
             0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    fileprivate var isRenderGridWideScalar: Bool {
        switch value {
        case 0x1100...0x115F,
             0x231A...0x231B,
             0x2329...0x232A,
             0x23E9...0x23EC,
             0x23F0,
             0x23F3,
             0x25FD...0x25FE,
             0x2614...0x2615,
             0x2648...0x2653,
             0x267F,
             0x2693,
             0x26A1,
             0x26AA...0x26AB,
             0x26BD...0x26BE,
             0x26C4...0x26C5,
             0x26CE,
             0x26D4,
             0x26EA,
             0x26F2...0x26F3,
             0x26F5,
             0x26FA,
             0x26FD,
             0x2705,
             0x270A...0x270B,
             0x2728,
             0x274C,
             0x274E,
             0x2753...0x2755,
             0x2757,
             0x2795...0x2797,
             0x27B0,
             0x27BF,
             0x2B1B...0x2B1C,
             0x2B50,
             0x2B55,
             0x2E80...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x16FE0...0x16FE4,
             0x16FF0...0x16FF6,
             0x17000...0x187FF,
             0x18800...0x18AFF,
             0x18B00...0x18CD5,
             0x18CFF,
             0x18D00...0x18D1E,
             0x18D80...0x18DF2,
             0x1AFF0...0x1AFF3,
             0x1AFF5...0x1AFFB,
             0x1AFFD...0x1AFFE,
             0x1B000...0x1B122,
             0x1B132,
             0x1B150...0x1B152,
             0x1B155,
             0x1B164...0x1B167,
             0x1B170...0x1B2FB,
             0x1D300...0x1D356,
             0x1D360...0x1D376,
             0x1F004,
             0x1F0CF,
             0x1F18E,
             0x1F191...0x1F19A,
             0x1F200...0x1F202,
             0x1F210...0x1F23B,
             0x1F240...0x1F248,
             0x1F250...0x1F251,
             0x1F260...0x1F265,
             0x1F300...0x1F320,
             0x1F32D...0x1F335,
             0x1F337...0x1F37C,
             0x1F37E...0x1F393,
             0x1F3A0...0x1F3CA,
             0x1F3CF...0x1F3D3,
             0x1F3E0...0x1F3F0,
             0x1F3F4,
             0x1F3F8...0x1F43E,
             0x1F440,
             0x1F442...0x1F4FC,
             0x1F4FF...0x1F53D,
             0x1F54B...0x1F54E,
             0x1F550...0x1F567,
             0x1F57A,
             0x1F595...0x1F596,
             0x1F5A4,
             0x1F5FB...0x1F64F,
             0x1F680...0x1F6C5,
             0x1F6CC,
             0x1F6D0...0x1F6D2,
             0x1F6D5...0x1F6D8,
             0x1F6DC...0x1F6DF,
             0x1F6EB...0x1F6EC,
             0x1F6F4...0x1F6FC,
             0x1F7E0...0x1F7EB,
             0x1F7F0,
             0x1F90C...0x1F93A,
             0x1F93C...0x1F945,
             0x1F947...0x1F9FF,
             0x1FA70...0x1FA7C,
             0x1FA80...0x1FA8A,
             0x1FA8E...0x1FAC6,
             0x1FAC8,
             0x1FACD...0x1FADC,
             0x1FADF...0x1FAEA,
             0x1FAEF...0x1FAF8,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    fileprivate var isRenderGridEmojiPresentationScalar: Bool {
        switch value {
        case 0xFE0F:
            return true
        default:
            return false
        }
    }

    fileprivate var isRenderGridAmbiguousWidthScalar: Bool {
        switch value {
        case 0x00A1,
             0x00A4,
             0x00A7...0x00A8,
             0x00AA,
             0x00AD...0x00AE,
             0x00B0...0x00B4,
             0x00B6...0x00BA,
             0x00BC...0x00BF,
             0x00C6,
             0x00D0,
             0x00D7...0x00D8,
             0x00DE...0x00E1,
             0x00E6,
             0x00E8...0x00EA,
             0x00EC...0x00ED,
             0x00F0,
             0x00F2...0x00F3,
             0x00F7...0x00FA,
             0x00FC,
             0x00FE,
             0x0101,
             0x0111,
             0x0113,
             0x011B,
             0x0126...0x0127,
             0x012B,
             0x0131...0x0133,
             0x0138,
             0x013F...0x0142,
             0x0144,
             0x0148...0x014B,
             0x014D,
             0x0152...0x0153,
             0x0166...0x0167,
             0x016B,
             0x01CE,
             0x01D0,
             0x01D2,
             0x01D4,
             0x01D6,
             0x01D8,
             0x01DA,
             0x01DC,
             0x0251,
             0x0261,
             0x02C4,
             0x02C7,
             0x02C9...0x02CB,
             0x02CD,
             0x02D0,
             0x02D8...0x02DB,
             0x02DD,
             0x02DF,
             0x0391...0x03A1,
             0x03A3...0x03A9,
             0x03B1...0x03C1,
             0x03C3...0x03C9,
             0x0401,
             0x0410...0x044F,
             0x0451,
             0x2010...0x2027,
             0x2030...0x205E,
             0x2074,
             0x207F,
             0x2081...0x2084,
             0x20AC,
             0x2103,
             0x2105,
             0x2109,
             0x2113,
             0x2116,
             0x2121...0x2122,
             0x2126,
             0x212B,
             0x2153...0x2154,
             0x215B...0x215E,
             0x2160...0x216B,
             0x2170...0x2179,
             0x2189,
             0x2190...0x21FF,
             0x2200...0x22FF,
             0x2300...0x2319,
             0x232C...0x23FF,
             0x2460...0x24E9,
             0x2500...0x259F,
             0x25A0...0x25FF,
             0x2600...0x27BF,
             0x2800...0x28FF,
             0x2B00...0x2BFF,
             0xE000...0xF8FF,
             0xFFFD:
            return true
        default:
            return false
        }
    }
}
