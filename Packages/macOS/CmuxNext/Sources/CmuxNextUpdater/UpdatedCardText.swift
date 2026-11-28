public import Foundation

/// The native "cmux Updated!" card's words (the App's `UpdatedCardIsland`), from the last update's
/// highlights: "Updated to Nightly", the top change's line ("Fixed: …") and the popover's rows.
/// The strings are the React card's, moved into the updater's catalog with their translations.
public nonisolated struct UpdatedCardText: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        /// The change's group (`new`, `fixed`, …): What's New opens at it.
        public var group: String
        public var area: String
        public var title: String
        public var summary: String?
        public var pr: URL?
    }

    /// "Updated to Nightly", or "Updated to Nightly in the background" after an automatic relaunch.
    public var headline: String
    /// The part of ``headline`` that names the build (a click copies ``version``).
    public var name: String
    public var version: String
    /// The top change's area label ("Fixed:"); nil when the line is a fallback.
    public var area: String?
    /// The second line: the top change, else "What's new in this build".
    public var line: String
    /// The popover's header ("Version 1.2.3 · 2026-11-30").
    public var versionLine: String
    public var changes: [Change]
    public var whatsNew: String { UpdaterStrings.text("updater.updatedCard.whatsNew", "What's New") }
    public var otherBuilds: String { UpdaterStrings.text("updater.updatedCard.otherBuilds", "Other builds") }
    public var copied: String { UpdaterStrings.text("updater.updatedCard.copied", "Copied") }
    public var copyVersion: String { UpdaterStrings.format("updater.updatedCard.copyVersion", "Copy Version %@", version) }
    /// "+3 more" for the changes past the first `shown`; nil when every change shows.
    public func more(past shown: Int) -> String? {
        changes.count > shown ? UpdaterStrings.format("updater.updatedCard.more", "+%@ more", String(changes.count - shown)) : nil
    }

    public init(_ highlights: UpdateHighlights, background: Bool) {
        version = highlights.version
        let nightly = highlights.version.range(of: #"^[^-]+-nightly\.\d+$"#, options: .regularExpression) != nil
        name = nightly ? UpdaterStrings.text("updater.updatedCard.nightly", "Nightly") : highlights.version
        headline = background
            ? UpdaterStrings.format("updater.updatedCard.updatedBehind", "Updated to %@ in the background", name)
            : UpdaterStrings.format("updater.updatedCard.updatedTo", "Updated to %@", name)
        let all = highlights.items + (highlights.rest ?? [])
        changes = all.map { Change(group: $0.category.rawValue, area: Self.area($0.category), title: $0.title, summary: $0.summary, pr: $0.pr) }
        if let top = changes.first {
            area = UpdaterStrings.format("updater.updatedCard.areaLabel", "%@:", top.area)
            line = top.title
        } else {
            area = nil
            line = UpdaterStrings.text("updater.updatedCard.whatsNewInBuild", "What's new in this build")
        }
        versionLine = highlights.date.map { UpdaterStrings.versionFrom(highlights.version, $0) } ?? highlights.version
    }

    static func area(_ category: UpdateHighlights.Category) -> String {
        switch category {
        case .new: UpdaterStrings.text("updater.updatedCard.new", "New")
        case .improved: UpdaterStrings.text("updater.updatedCard.improved", "Improved")
        case .fixed: UpdaterStrings.text("updater.updatedCard.fixed", "Fixed")
        case .security: UpdaterStrings.text("updater.updatedCard.security", "Security")
        }
    }
}
