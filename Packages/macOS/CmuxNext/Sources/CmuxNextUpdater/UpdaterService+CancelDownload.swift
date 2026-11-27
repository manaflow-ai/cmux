import Foundation

/// The download's cancel on the notice card (Leo 2026-10-31: "AND WHY CAN'T I CANCEL THE DOWNLOAD
/// OPTIONALLY"). Sparkle's cancellation stops the transfer and deletes the partial file; the card
/// then goes back to the found update, whose Update checks again and downloads what it finds.
struct CancelledDownload: Equatable {
    /// The found update's display version, when Sparkle named it.
    var version: String?
}

extension UpdaterService {
    /// The cancel on the downloading card: stops the download and shows the found update again.
    /// Nothing happens unless a download runs (a late click after it finished does nothing).
    public func cancelDownloadClicked() {
        syncFlowPhase()
        guard case .downloading(let transfer) = flow.phase, transfer.stage == .downloading else {
            log.append("download cancel ignored: no download runs (\(flow.phase))")
            return
        }
        let version = controller?.model.detectedUpdateVersion
        guard cancelDownloadNow() else {
            log.append("download cancel ignored: Sparkle holds no download to cancel")
            return
        }
        log.append("download cancelled by the person; the partial file is removed")
        downloadAfterCheck = false
        cancelledDownload = CancelledDownload(version: version)
        syncFlowPhase()
    }

    /// The card a cancelled download leaves: its found update, until Sparkle moves again.
    var cancelledDownloadCard: UpdateCard? {
        guard let cancelledDownload, flow.phase == .hidden else { return nil }
        if updateSnooze.hides(version: cancelledDownload.version, at: now()) { return nil }
        return .available(version: cancelledDownload.version)
    }

    /// Update on a cancelled download's card: Sparkle let go of the found update, so check
    /// again; the update the check finds downloads (``followCancelledDownload(_:)``). Returns
    /// whether the click was this card's.
    func downloadAgainIfCancelled() -> Bool {
        guard cancelledDownload != nil, flow.phase == .hidden else { return false }
        cancelledDownload = nil
        downloadAfterCheck = true
        log.append("update after a cancelled download: checking again")
        checkForUpdates()
        return true
    }

    /// Follows Sparkle after a cancel: any move ends the cancelled card; the check that Update
    /// started downloads the update it finds, and ends with its result otherwise.
    func followCancelledDownload(_ phase: UpdateIndicatorPhase) {
        defer { lastCancelFollowed = phase }
        if phase != .hidden { cancelledDownload = nil }
        guard downloadAfterCheck else { return }
        switch phase {
        case .checking:
            break
        case .hidden:
            // The check ended with nothing (cancelled, or idle before a result): a later scheduled
            // check's update never downloads on this old click. A hidden phase before the check
            // starts (the cancel's own idle) keeps it.
            if lastCancelFollowed == .checking { downloadAfterCheck = false }
        case .available:
            downloadAfterCheck = false
            send(.downloadRequested)
        case .downloading, .ready, .installing, .note:
            downloadAfterCheck = false
        }
    }
}
