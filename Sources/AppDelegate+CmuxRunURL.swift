import AppKit
import Foundation

extension AppDelegate {
    @discardableResult
    func handleCmuxExternalURLs(from urls: [URL]) -> Bool {
        let intentCounts = Self.cmuxExternalURLIntentCounts(in: urls)
        guard intentCounts.total > 0 else { return false }
        if intentCounts.run > 0,
           isHandlingCmuxRunURLRequest || pendingStartupRunURLRequest != nil {
            return true
        }
        guard intentCounts.total == 1 else {
            if intentCounts.run > 0 {
                CmuxRunURLConfirmationPresenter().showParseFailure(.multipleLinks)
            } else if intentCounts.ssh > 1 && intentCounts.navigation == 0 && intentCounts.text == 0 {
                showCmuxSSHURLParseError(.multipleLinks)
            } else {
                showCmuxTextURLParseError(.multipleLinks)
            }
            return true
        }

        if handleCmuxRunURLs(from: urls) {
            return true
        }
        if handleCmuxSSHURLs(from: urls) {
            return true
        }
        if handleCmuxNavigationURLs(from: urls) {
            return true
        }
        if handleCmuxTextURLs(from: urls) {
            return true
        }
        return false
    }

    struct CmuxExternalURLIntentCounts {
        var run = 0
        var ssh = 0
        var navigation = 0
        var text = 0

        var total: Int {
            run + ssh + navigation + text
        }
    }

    private enum CmuxExternalURLIntent {
        case run
        case ssh
        case navigation
        case text
    }

    static func cmuxExternalURLIntentCounts(
        in urls: [URL],
        supportedSchemes: Set<String> = CmuxRunURLRequest.activeSupportedSchemes
    ) -> CmuxExternalURLIntentCounts {
        urls.reduce(CmuxExternalURLIntentCounts()) { counts, url in
            var nextCounts = counts
            switch cmuxExternalURLIntent(for: url, supportedSchemes: supportedSchemes) {
            case .run:
                nextCounts.run += 1
            case .ssh:
                nextCounts.ssh += 1
            case .navigation:
                nextCounts.navigation += 1
            case .text:
                nextCounts.text += 1
            case nil:
                break
            }
            return nextCounts
        }
    }

    private static func cmuxExternalURLIntent(
        for url: URL,
        supportedSchemes: Set<String>
    ) -> CmuxExternalURLIntent? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "ssh" {
            return .ssh
        }
        guard supportedSchemes.contains(scheme) else { return nil }

        let normalizedHost = url.host?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let route = normalizedHost.flatMap { $0.isEmpty ? nil : $0 }
            ?? url.path.split(separator: "/").first.map { String($0).lowercased() }
        switch route {
        case "run":
            return .run
        case "ssh":
            return .ssh
        case "workspace":
            return .navigation
        case "prompt", "rule", "rules":
            return .text
        default:
            return nil
        }
    }

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
