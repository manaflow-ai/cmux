import CmuxNextDesign
import CmuxNextPages

/// The What's New page designs (cx-urd.61; Debug Settings `whatsNew.design`, DEV and NIGHTLY only;
/// Release always shows the default). The What's New sheet is the default since 2026-10-31; the
/// Ledger (u5099, default before it), the journal, the rail and the digest stay selectable here.
nonisolated enum WhatsNewDesign: String, Sendable, CaseIterable, TunableChoice {
    case sheet, ledger, journal, rail, digest

    var tunableTitle: String {
        switch self {
        case .sheet: "What's New sheet (icon, bold title, one line per change)"
        case .ledger: "Ledger (Conductor style, version and date in the margin)"
        case .journal: "A: Journal (one column, releases stacked)"
        case .rail: "B: Rail + reader"
        case .digest: "C: Digest (dense list, no hero)"
        }
    }
}

nonisolated enum WhatsNewTunables {
    static let design = Tunable<WhatsNewDesign>.choice(
        "whatsNew.design", PageTunables.section, "What's New design",
        help: "Design of the What's New page. Applies the next time the page opens.",
        default: .sheet, code: "WhatsNewTunables.design")

    static var all: [TunableDescriptor] { [design.descriptor] }
}
