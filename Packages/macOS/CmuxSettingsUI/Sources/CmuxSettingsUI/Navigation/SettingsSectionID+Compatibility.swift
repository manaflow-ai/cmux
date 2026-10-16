import Foundation

extension SettingsSectionID {
    /// Scroll anchors that pointed at Devices before it became its own
    /// section: the old Computers pairing row, and the subsection it was
    /// nested as under Mobile. Persisted navigation targets and older
    /// callers still send them.
    static let legacyDevicesAnchorIDs: Set<String> = [
        "setting:computers:pair",
        "setting:mobile:computers"
    ]

    /// The section a navigation request for this id selects, and the anchor
    /// the detail pane scrolls to.
    ///
    /// Sidebar selection and the detail scroll both resolve through here so
    /// they cannot disagree about where a request lands. A request without
    /// an anchor lands on the section header; a legacy Devices anchor lands
    /// on the Devices header whichever section it was posted for.
    func navigationDestination(providedAnchor: String?) -> (section: SettingsSectionID, anchorID: String) {
        if let providedAnchor, Self.legacyDevicesAnchorIDs.contains(providedAnchor) {
            return (.computers, "section:\(Self.computers.rawValue)")
        }
        return (self, providedAnchor ?? "section:\(rawValue)")
    }

    /// Decodes a `cmux.settings.navigate` notification's `target` and
    /// optional `anchor`, or returns `nil` for an unknown target.
    static func navigationDestination(
        userInfo: [AnyHashable: Any]?
    ) -> (section: SettingsSectionID, anchorID: String)? {
        guard
            let rawValue = userInfo?["target"] as? String,
            let requested = SettingsSectionID(rawValue: rawValue)
        else { return nil }
        return requested.navigationDestination(providedAnchor: userInfo?["anchor"] as? String)
    }
}
