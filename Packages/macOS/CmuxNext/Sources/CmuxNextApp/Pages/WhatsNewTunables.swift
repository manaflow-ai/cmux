import CmuxNextDesign
import CmuxNextPages

/// The What's New page designs (cx-urd.61; Debug Settings `whatsNew.design`, DEV and NIGHTLY only;
/// Release always shows the default). The Ledger is the default since u5099 (2026-10-20, the
/// Conductor-style #01 of design/changelog-variations-gallery); the journal it is laid out from,
/// the rail and the digest stay selectable here.
nonisolated enum WhatsNewDesign: String, Sendable, CaseIterable, TunableChoice {
    case ledger, journal, rail, digest

    var tunableTitle: String {
        switch self {
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
        default: .ledger, code: "WhatsNewTunables.design")

    static var all: [TunableDescriptor] { [design.descriptor] }
}
