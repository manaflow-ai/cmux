import AppKit

struct DSLFontSpec {
    let baseSize: CGFloat
    let weight: NSFont.Weight?
    let design: DSLFontDesign
}

enum DSLFontDesign {
    case `default`
    case monospaced
    case rounded
    case serif
}
