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
    /// Changelog lines under the detail (a found update; cx-lntk).
    public var lines: [String] = []
    public var dismissible = true
    /// Hides itself after this long (up to date); nil waits for the user.
    public var dismissesAfter: Duration?
}

extension UpdateCard {
    /// The card for the running build (`version` = CFBundleShortVersionString,
    /// `build` = CFBundleVersion); `install` says what an ``installing`` card waits on.
    nonisolated public func presentation(version: String, build: String, install: UpdateInstallStatus? = nil) -> UpdateCardPresentation {
        let current = Self.versionLabel(version: version, build: build)
        switch self {
        case .checking:
            return UpdateCardPresentation(symbol: "arrow.triangle.2.circlepath", title: UpdaterStrings.checking,
                                          detail: UpdaterStrings.youHave(current), showsProgress: true, dismissible: false)
        case .downloading(let transfer):
            // One card through the whole download (Lawrence 2026-10-20): the stage, the bytes, the bar.
            switch transfer.stage {
            case .starting:
                return UpdateCardPresentation(symbol: "arrow.down.circle", title: UpdaterStrings.startingDownload,
                                              detail: UpdaterStrings.keepsRunning, showsProgress: true, dismissible: false)
            case .downloading:
                return UpdateCardPresentation(symbol: "arrow.down.circle", title: UpdaterStrings.downloading,
                                              detail: transfer.bytesText ?? UpdaterStrings.keepsRunning, showsProgress: true,
                                              progress: transfer.fraction, dismissible: false)
            case .preparing:
                return UpdateCardPresentation(symbol: "shippingbox", title: UpdaterStrings.preparing,
                                              detail: UpdaterStrings.preparingDetail, showsProgress: true,
                                              progress: transfer.fraction, dismissible: false)
            }
        case .installing:
            return Self.installing(install)
        case .available(let found):
            return UpdateCardPresentation(symbol: "arrow.down.circle", title: UpdaterStrings.noticeAvailable,
                                          detail: found.map(UpdaterStrings.foundVersion) ?? UpdaterStrings.youHave(current),
                                          actions: [.update, .releaseNotes])
        case .note(.upToDate):
            return UpdateCardPresentation(symbol: "checkmark.circle", title: UpdaterStrings.upToDate,
                                          detail: UpdaterStrings.upToDateDetail(current), dismissesAfter: UpdateCard.upToDateDuration)
        case .note(.checkFailed):
            return UpdateCardPresentation(symbol: "exclamationmark.triangle", title: UpdaterStrings.noticeCheckFailed,
                                          detail: UpdaterStrings.checkFailedDetail, actions: [.retry, .details])
        case .note(.found(let found)):
            return UpdateCardPresentation(symbol: "arrow.down.circle", title: UpdaterStrings.noticeAvailable,
                                          detail: UpdaterStrings.foundVersion(found), actions: [.releaseNotes])
        case .note(.needsNewerMacOS(let found, let required)):
            return UpdateCardPresentation(symbol: "desktopcomputer", title: UpdaterStrings.noticeAvailable,
                                          detail: UpdaterStrings.needsMacOSDetail(found, required))
        case .pulled(let reason, let kept):
            // "Wait for the Fix" is the default (first, prominent); Roll Back only when it would run.
            return UpdateCardPresentation(symbol: "exclamationmark.octagon", title: UpdaterStrings.pulledTitle,
                                          detail: reason.isEmpty ? nil : reason,
                                          actions: kept == nil ? [.waitForFix] : [.waitForFix, .rollBack],
                                          lines: [kept.map(UpdaterStrings.pulledKept) ?? UpdaterStrings.pulledNothingKept])
        }
    }

    /// The installing card for `status` (``UpdateInstallStatus``): the short text first, then
    /// the step and its seconds, or that the install never relaunched (with Details).
    nonisolated static func installing(_ status: UpdateInstallStatus?) -> UpdateCardPresentation {
        let symbol = "arrow.clockwise.circle"
        guard let status else {
            return UpdateCardPresentation(symbol: symbol, title: UpdaterStrings.installingUpdate,
                                          detail: UpdaterStrings.relaunchingDetail, showsProgress: true, dismissible: false)
        }
        switch status.stage {
        case .stalled:
            return UpdateCardPresentation(symbol: "exclamationmark.triangle", title: UpdaterStrings.installStalled,
                                          detail: UpdaterStrings.installStalledDetail(minutes: max(1, status.seconds / 60)),
                                          actions: [.details])
        case .preparing:
            return UpdateCardPresentation(symbol: symbol, title: UpdaterStrings.installingUpdate,
                                          detail: status.isSlow ? UpdaterStrings.checkingNewVersion(seconds: status.seconds)
                                                                : UpdaterStrings.relaunchingDetail,
                                          showsProgress: true, dismissible: false)
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
        case .installing: "installing"
        case .available: "available"
        case .note(.upToDate): "up_to_date"
        case .note(.checkFailed): "check_failed"
        case .note(.found): "found"
        case .note(.needsNewerMacOS): "requires_newer_macos"
        case .pulled: "pulled"
        }
    }
}
