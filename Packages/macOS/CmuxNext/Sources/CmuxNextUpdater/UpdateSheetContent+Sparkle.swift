public import CmuxUpdater
import Foundation
@preconcurrency import Sparkle

extension UpdateSheetContent {
    /// The sheet for a Sparkle phase; nil when Sparkle is idle (the sheet closes).
    @MainActor
    public static func sparkle(_ state: UpdateState, current identity: UpdateBuildIdentity) -> UpdateSheetContent? {
        let current = UpdaterStrings.currentVersion(identity.shortVersion, identity.build)
        switch state {
        case .idle:
            return nil
        case .permissionRequest, .preparingCheck, .checking:
            return UpdateSheetContent(symbol: checkingSymbol, title: UpdaterStrings.checking, progress: .indeterminate, buttons: [.cancel])
        case .updateAvailable(let available):
            let version = available.appcastItem.displayVersionString
            let notes = available.releaseNotes.map { UpdateSheetButton.releaseNotes($0.url) }
            return UpdateSheetContent(symbol: "arrow.down.circle",
                                      title: version.isEmpty ? UpdaterStrings.availableNoVersion : UpdaterStrings.available(version),
                                      detail: current, link: notes, buttons: [.later, .install])
        case .notFound:
            return UpdateSheetContent(symbol: "checkmark.circle", title: UpdaterStrings.upToDate,
                                      detail: UpdaterStrings.onChannel(identity.shortVersion, identity.build, UpdaterStrings.channel(identity.track)),
                                      buttons: [.done])
        case .error(let failure):
            let detail = (failure.error as NSError).localizedDescription
            return UpdateSheetContent(symbol: "exclamationmark.triangle", title: UpdaterStrings.updateFailed, detail: detail, buttons: [.done, .retry])
        case .startingDownload:
            return UpdateSheetContent(symbol: "arrow.down.circle", title: UpdaterStrings.startingDownload, progress: .indeterminate, buttons: [])
        case .downloading(let download):
            let fraction = download.expectedLength.flatMap { $0 > 0 ? Double(download.progress) / Double($0) : nil }
            return UpdateSheetContent(symbol: "arrow.down.circle", title: UpdaterStrings.downloading,
                                      progress: fraction.map { .fraction(min(max($0, 0), 1)) } ?? .indeterminate, buttons: [.cancel])
        case .extracting(let extracting):
            return UpdateSheetContent(symbol: "shippingbox", title: UpdaterStrings.preparing,
                                      progress: .fraction(min(max(extracting.progress, 0), 1)), buttons: [])
        case .installing(let installing):
            guard installing.isAutoUpdate || installing.relaunchBlockers != nil else {
                return UpdateSheetContent(symbol: "shippingbox", title: UpdaterStrings.installing, progress: .indeterminate, buttons: [])
            }
            return UpdateSheetContent(symbol: "arrow.clockwise.circle", title: UpdaterStrings.readyToInstall,
                                      detail: UpdaterStrings.readyDetail, buttons: [.later, .relaunch])
        }
    }
}
