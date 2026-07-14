import AppKit
import Foundation

extension AppDelegate {
    @discardableResult
    func handleCmuxRunURLs(from urls: [URL]) -> Bool {
        var requests: [CmuxRunURLRequest] = []
        var errors: [CmuxRunURLParseError] = []
        for url in urls {
            switch CmuxRunURLRequest.parse(url) {
            case .success(.some(let request)):
                requests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                errors.append(error)
            }
        }

        let intentCount = requests.count + errors.count
        guard intentCount > 0 else { return false }
        guard !isHandlingCmuxRunURLRequest,
              pendingStartupRunURLRequest == nil,
              NSApp.modalWindow == nil else {
            return true
        }
        guard intentCount == 1 else {
            CmuxRunURLConfirmationPresenter().showParseFailure(.multipleLinks)
            return true
        }
        if let error = errors.first {
            CmuxRunURLConfirmationPresenter().showParseFailure(error)
            return true
        }
        if let request = requests.first {
            return CmuxRunURLCoordinator(appDelegate: self).handle(request)
        }
        return true
    }

    func flushPendingStartupRunURLRequest() {
        guard let request = pendingStartupRunURLRequest else { return }
        pendingStartupRunURLRequest = nil
        _ = CmuxRunURLCoordinator(appDelegate: self).handle(request)
    }
}
