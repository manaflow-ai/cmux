import Foundation

extension Array where Element == CuratedSettingEntry {
    /// `entries` followed by ``devicesEntries``. A call rather than `+` at the
    /// end of ``cmuxDefault(catalog:)`` keeps that large literal's contextual
    /// type concrete, so it type-checks without operator overload search.
    static func appendingDevicesEntries(to entries: [CuratedSettingEntry]) -> [CuratedSettingEntry] {
        entries + devicesEntries
    }

    /// Search entries for the two Devices switches, so a query such as
    /// "discovery" or "discoverable" scrolls to the row itself rather than
    /// only to the section header. Titles and details match the rows in
    /// ``ComputersSection`` and the Cloud sidebar's My Devices menu.
    ///
    /// Neither switch is a cmux.json setting, so the entries declare no
    /// paths and the synonyms carry no dotted tokens.
    static var devicesEntries: [CuratedSettingEntry] {
        [
            .init(
                section: .computers,
                id: "incoming-access",
                title: String(localized: "devices.incoming.toggle", defaultValue: "Make this Mac discoverable"),
                detailText: String(localized: "devices.incoming.help", defaultValue: "Turning this off removes this Mac from discovery and disconnects incoming sessions. You can still connect to your other Macs."),
                synonyms: "Make this Mac discoverable allow access to this mac incoming access host share my devices"
            ),
            .init(
                section: .computers,
                id: "discovery",
                title: String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs"),
                detailText: String(localized: "devices.discovery.help", defaultValue: "Find and connect to other Macs signed in to your account. Turning this off disconnects their panes without closing their terminals."),
                synonyms: "Discover other Macs discovery find connect other computers my devices"
            )
        ]
    }
}
