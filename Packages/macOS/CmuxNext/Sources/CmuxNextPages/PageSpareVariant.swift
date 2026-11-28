import Foundation
import os

/// What the page host pool's parked spare holds until a claim (`CMUX_NEXT_SETTINGS_SPARE`, a measurement
/// prototype; the default is unchanged). Leo: "we cannot trade off instant loads. instant > memory": a
/// variant other than `.painted` becomes a default only with Cmd-, numbers from the bench of its RAM.
public enum PageSpareVariant: String, Sendable, CaseIterable {
    /// The Settings document loaded, React rendered and painted once, then hidden.
    case painted
    /// The Settings bundle loaded and parsed, but no React root until the claim (the claim mounts it; the default).
    case unmounted
    // Measured and dropped (cmux#48756): a spare hidden from its park (-12 MB) queued a first-paint
    // report the claim then took for its own, and a blank document (-64 MB) opened Settings cold in 278 ms.

    /// The variant this launch uses: `CMUX_NEXT_SETTINGS_SPARE`, else ``defaultVariant``.
    public static let current = variant(ProcessInfo.processInfo.environment["CMUX_NEXT_SETTINGS_SPARE"])

    /// The variant with no environment value.
    public static let defaultVariant: PageSpareVariant = .unmounted

    static func variant(_ value: String?) -> PageSpareVariant {
        guard let value, !value.isEmpty else { return defaultVariant }
        guard let variant = PageSpareVariant(rawValue: value.lowercased()) else {
            // A typo would otherwise bench the default against itself and read as "no change".
            Logger(subsystem: "com.cmuxterm.app.next", category: "pages")
                .error("CMUX_NEXT_SETTINGS_SPARE=\(value, privacy: .public) is not a variant; using \(defaultVariant.rawValue, privacy: .public)")
            return defaultVariant
        }
        return variant
    }

    /// The document-start flag that tells a parked page to mount only at its claim (webviews pageClient.ts).
    static let deferMountScript = "globalThis.__cmuxPageDeferMount = true;"
}
