import AppKit
import Foundation

extension AppDelegate {
    @discardableResult
    func handleCmuxExternalURLs(from urls: [URL]) -> Bool {
        let intentCounts = Self.cmuxExternalURLIntentCounts(in: urls)
        let admission = Self.cmuxExternalURLAdmission(
            intentCounts: intentCounts,
            isRunBusy: cmuxRunURLCoordinator.isBusy || NSApp.modalWindow != nil
        )
        switch admission {
        case .none:
            return false
        case .multipleRunLinks:
            cmuxRunURLConfirmationPresenter.showNonModalParseFailure(.multipleLinks)
            return true
        case .multipleSSHLinks:
            showCmuxSSHURLParseError(.multipleLinks)
            return true
        case .multipleNonRunLinks:
            showCmuxTextURLParseError(.multipleLinks)
            return true
        case .busy:
            cmuxRunURLConfirmationPresenter.showNonModalFailure(.busy)
            return true
        case .route:
            break
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

    static func cmuxExternalURLAdmission(
        intentCounts: CmuxExternalURLIntentCounts,
        isRunBusy: Bool
    ) -> CmuxExternalURLAdmission {
        guard intentCounts.total > 0 else { return .none }
        guard intentCounts.total == 1 else {
            if intentCounts.run > 0 {
                return .multipleRunLinks
            }
            if intentCounts.ssh > 1,
               intentCounts.navigation == 0,
               intentCounts.text == 0 {
                return .multipleSSHLinks
            }
            return .multipleNonRunLinks
        }
        let executableIntentCount = intentCounts.run + intentCounts.ssh + intentCounts.text
        if executableIntentCount == 1, isRunBusy {
            return .busy
        }
        return .route
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
        guard !cmuxRunURLCoordinator.isBusy,
              NSApp.modalWindow == nil else {
            cmuxRunURLConfirmationPresenter.showNonModalFailure(.busy)
            return true
        }
        guard intentCount == 1 else {
            cmuxRunURLConfirmationPresenter.showNonModalParseFailure(.multipleLinks)
            return true
        }
        if let error = errors.first {
            cmuxRunURLConfirmationPresenter.showParseFailure(error)
            return true
        }
        if let request = requests.first {
            return cmuxRunURLCoordinator.handle(request)
        }
        return true
    }

    func flushPendingStartupRunURLRequest() {
        cmuxRunURLCoordinator.flushPendingStartupRequest()
    }
}
