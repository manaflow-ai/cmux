import Foundation

extension SettingsSectionID {
    /// The canonical visible destination for this section id.
    ///
    /// `computers` is retained as a raw-value compatibility target for
    /// existing `cmux settings open computers` requests and persisted
    /// navigation notifications. It is intentionally not a visible section;
    /// the destination now lives inside Mobile.
    var canonicalSection: Self {
        switch self {
        case .computers:
            return .mobile
        default:
            return self
        }
    }

    /// Whether this id represents a destination shown in the Settings UI.
    var isVisibleSection: Bool { self == canonicalSection }

    /// Section ids that may appear in the browse sidebar or own a mounted
    /// detail slot. Compatibility aliases are excluded.
    static var visibleCases: [Self] {
        allCases.filter(\.isVisibleSection)
    }

    /// Stable anchor for the Computers subsection inside Mobile.
    static let computersSubsectionAnchorID = "setting:mobile:computers"

    /// Resolves this destination's scroll anchor, including legacy requests
    /// that omitted their anchor entirely.
    ///
    /// Older callers used either the section anchor or the section's pairing
    /// row anchor. Both now resolve to the nested subsection so search hits,
    /// persisted requests, and `cmux settings open computers` remain useful.
    func canonicalNavigationAnchor(providedAnchor: String?) -> String {
        let anchorID = providedAnchor ?? "section:\(rawValue)"
        if anchorID == "section:computers"
            || anchorID.hasPrefix("setting:computers:") {
            return Self.computersSubsectionAnchorID
        }
        return anchorID
    }
}
