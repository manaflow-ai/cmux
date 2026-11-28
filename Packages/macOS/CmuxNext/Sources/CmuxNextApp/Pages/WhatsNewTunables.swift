import CmuxNextDesign
import CmuxNextPages

/// The What's New page designs (cx-urd.61; Debug Settings `whatsNew.design`, DEV and NIGHTLY only;
/// Release always shows the journal). Lawrence picked the journal on 2026-10-11; the rail and the
/// digest are deleted once he has used the journal.
nonisolated enum WhatsNewDesign: String, Sendable, CaseIterable, TunableChoice {
    case journal, rail, digest

    var tunableTitle: String {
        switch self {
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
        default: .journal, code: "WhatsNewTunables.design")

    static var all: [TunableDescriptor] { [design.descriptor] }
}
