import Observation

/// The Cloud previews this app opened in a browser pane (`cloud.preview.open`), by origin: what the
/// pane's Publish button (RFD 0003 E-A, `experiments.appsTier`) asks Rust about
/// (``AppsTierRules/target(url:title:previews:)``), since a preview's URL alone names no machine.
/// Observed: the toolbar of a tab that opened before its preview was recorded shows the button
/// once it is. One per app (`AppServices.appsTierPreviews`).
@MainActor
@Observable
public final class AppsTierPreviews {
    /// The previews opened, by origin; a later opening of the same origin replaces it.
    public private(set) var known: [String: AppsTierRules.KnownPreview] = [:]

    public init() {}

    public func record(_ preview: AppsTierRules.KnownPreview) {
        guard known[preview.origin] != preview else { return }
        known[preview.origin] = preview
    }

    public var previews: [AppsTierRules.KnownPreview] { Array(known.values) }
}
