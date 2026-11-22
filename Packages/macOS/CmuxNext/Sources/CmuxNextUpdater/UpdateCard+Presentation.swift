import Foundation

/// The notice card's content for an ``UpdateCard`` (localized): an SF
/// Symbol, a title, one short detail line, the actions that apply, whether
/// it has an x, and when it hides itself.
nonisolated public struct UpdateCardPresentation: Equatable, Sendable {
    public var symbol: String
    public var title: String
    public var detail: String?
    /// Shows a progress bar: `progress` 0...1, or nil while unmeasured.
    public var showsProgress = false
    public var progress: Double?
    public var actions: [UpdateCardAction] = []
    public var dismissible = true
    /// Hides itself after this long (up to date); nil waits for the user.
    public var dismissesAfter: Duration?
}

extension UpdateCard {
    /// The card for the running build (`version` = CFBundleShortVersionString,
    /// `build` = CFBundleVersion).
    nonisolated public func presentation(version: String, build: String) -> UpdateCardPresentation {
        let current = Self.versionLabel(version: version, build: build)
        switch self {
        case .checking:
            return UpdateCardPresentation(symbol: "arrow.triangle.2.circlepath", title: UpdaterStrings.checking,
                                          detail: UpdaterStrings.youHave(current), showsProgress: true, dismissible: false)
        case .downloading(let progress):
            return UpdateCardPresentation(symbol: "arrow.down.circle", title: UpdaterStrings.downloading,
                                          detail: UpdaterStrings.keepsRunning, showsProgress: true, progress: progress, dismissible: false)
        case .available(let found):
            return UpdateCardPresentation(symbol: "arrow.down.circle",
                                          title: found.map(UpdaterStrings.available) ?? UpdaterStrings.availableNoVersion,
                                          detail: UpdaterStrings.youHave(current), actions: [.update, .releaseNotes])
        case .note(.upToDate):
            return UpdateCardPresentation(symbol: "checkmark.circle", title: UpdaterStrings.upToDate,
                                          detail: UpdaterStrings.upToDateDetail(current), dismissesAfter: UpdateCard.upToDateDuration)
        case .note(.checkFailed):
            return UpdateCardPresentation(symbol: "exclamationmark.triangle", title: UpdaterStrings.checkFailed,
                                          detail: UpdaterStrings.checkFailedDetail, actions: [.retry, .details])
        case .note(.found(let found)):
            return UpdateCardPresentation(symbol: "arrow.down.circle", title: UpdaterStrings.available(found),
                                          detail: UpdaterStrings.disabledDevelopment, actions: [.releaseNotes])
        case .note(.needsNewerMacOS(let required)):
            return UpdateCardPresentation(symbol: "desktopcomputer", title: UpdaterStrings.needsNewerMacOS(required),
                                          detail: UpdaterStrings.youHave(current))
        }
    }

    /// How long "up to date" stays.
    nonisolated static let upToDateDuration: Duration = .seconds(4)

    /// "1.0.0-nightly.3752664687401" already names its build; a stable
    /// "0.65.0" gets "(108)".
    nonisolated static func versionLabel(version: String, build: String) -> String {
        version.hasSuffix(build) ? version : "\(version) (\(build))"
    }

    /// A stable name for scripts (`updates.status.card.kind`).
    nonisolated public var kind: String {
        switch self {
        case .checking: "checking"
        case .downloading: "downloading"
        case .available: "available"
        case .note(.upToDate): "up_to_date"
        case .note(.checkFailed): "check_failed"
        case .note(.found): "found"
        case .note(.needsNewerMacOS): "requires_newer_macos"
        }
    }
}
