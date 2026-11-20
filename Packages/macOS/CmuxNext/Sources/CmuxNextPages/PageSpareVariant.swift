import Foundation

/// What the page host pool's parked spare holds until a claim (`CMUX_NEXT_SETTINGS_SPARE`, a measurement
/// prototype; the default is unchanged). Leo: "we cannot trade off instant loads. instant > memory": a
/// variant other than `.painted` becomes a default only with Cmd-, numbers from the bench of its RAM.
public enum PageSpareVariant: String, Sendable, CaseIterable {
    /// The Settings document loaded, React rendered and painted once, then hidden (the default).
    case painted
    /// The Settings bundle loaded and parsed, but no React root until the claim (the claim mounts it).
    case unmounted
    /// The Settings document loaded and rendered in a view hidden from its park: no first paint until the claim.
    case hidden
    /// A blank document in a running WebContent process: the claim loads Settings.
    case blank

    /// The variant this launch uses: `CMUX_NEXT_SETTINGS_SPARE`, else ``defaultVariant``.
    public static let current = variant(ProcessInfo.processInfo.environment["CMUX_NEXT_SETTINGS_SPARE"])

    /// The variant with no environment value.
    public static let defaultVariant: PageSpareVariant = .painted

    static func variant(_ value: String?) -> PageSpareVariant {
        value.flatMap { PageSpareVariant(rawValue: $0.lowercased()) } ?? defaultVariant
    }

    /// The document-start flag that tells a parked page to mount only at its claim (webviews pageClient.ts).
    static let deferMountScript = "globalThis.__cmuxPageDeferMount = true;"
}
