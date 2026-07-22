import AppKit
import CmuxTerminalCore
import CmuxTestSupport
import Foundation

/// Owns terminal-link policy and routes the resulting action through whichever
/// panel container currently owns the source terminal.
@MainActor
struct TerminalLinkOpenCoordinator {
    private let defaults: UserDefaults
    private let containerResolver: @MainActor (UUID?, UUID?) -> (any TerminalLinkOpenContainer)?
    private let externalOpen: @MainActor @Sendable (URL) -> Bool
    private let deferOperation: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void

    init(
        defaults: UserDefaults = .standard,
        containerResolver: @escaping @MainActor (UUID?, UUID?) -> (any TerminalLinkOpenContainer)? = Self.resolveContainer,
        externalOpen: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) },
        deferOperation: @escaping @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void = { operation in
            Task { @MainActor in operation() }
        }
    ) {
        self.defaults = defaults
        self.containerResolver = containerResolver
        self.externalOpen = externalOpen
        self.deferOperation = deferOperation
    }

    @discardableResult
    func open(_ request: TerminalLinkOpenRequest) -> Bool {
        log("link.openURL raw=\(request.rawValue)")

        let trimmed = request.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let container = containerResolver(request.sourceWorkspaceId, request.sourcePanelId)
        var normalizedOpenURLString = request.rawValue

        let canResolveLocalFilePath: Bool
        if let sourcePanelId = request.sourcePanelId, let container {
            canResolveLocalFilePath = !container.terminalLinkIsRemoteTerminal(sourcePanelId)
        } else {
            canResolveLocalFilePath = false
        }
        if !trimmed.isEmpty,
           canResolveLocalFilePath,
           let resolvedPath = TerminalPathResolver().resolveOpenURLFilePath(
               trimmed,
               cwd: resolvedWorkingDirectory(request: request, container: container)
           ) {
            let fileURL = URL(fileURLWithPath: resolvedPath)
            if CommandClickFileOpenRouter.shouldRouteInCmux(path: resolvedPath) {
                log("link.openURL resolvedAsFilePath=\(resolvedPath)")
                guard let sourcePanelId = request.sourcePanelId,
                      let container,
                      container.deferTerminalFileLinkOpen(
                          sourcePanelId: sourcePanelId,
                          filePath: resolvedPath,
                          fallback: { [externalOpen] in _ = externalOpen(fileURL) }
                      ) else {
                    return openExternally(fileURL, reason: "file route unavailable")
                }
                return true
            }
            normalizedOpenURLString = resolvedPath
        }

        guard let target = resolveTerminalOpenURLTarget(normalizedOpenURLString) else {
            log("link.openURL resolve failed")
            return false
        }

        #if DEBUG
        if UITestCaptureSink().appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH",
            line: target.url.absoluteString
        ) {
            return true
        }
        #endif

        if TerminalOpenURLFileRoutingPolicy().shouldAttemptCmuxFileRouting(
            rawOpenURLValue: trimmed,
            target: target
        ), CommandClickFileOpenRouter.shouldRouteInCmux(path: target.url.path) {
            guard let sourcePanelId = request.sourcePanelId,
                  let container,
                  !container.terminalLinkIsRemoteTerminal(sourcePanelId),
                  container.deferTerminalFileLinkOpen(
                      sourcePanelId: sourcePanelId,
                      filePath: target.url.path,
                      fallback: { [externalOpen] in _ = externalOpen(target.url) }
                  ) else {
                return openExternally(target.url, reason: "file container unavailable")
            }
            return true
        }

        guard BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults) else {
            return openExternally(target.url, reason: "cmux browser disabled")
        }

        switch target {
        case .external(let url):
            return openExternally(url, reason: "external target")
        case .embeddedBrowser(let url):
            return openEmbeddedBrowserURL(url, request: request, container: container)
        }
    }

    private func openEmbeddedBrowserURL(
        _ url: URL,
        request: TerminalLinkOpenRequest,
        container: (any TerminalLinkOpenContainer)?
    ) -> Bool {
        if BrowserLinkOpenSettings.shouldOpenExternally(url, defaults: defaults) {
            return openExternally(url, reason: "external pattern")
        }
        guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
            return openExternally(url, reason: "invalid host")
        }
        guard BrowserLinkOpenSettings.hostMatchesWhitelist(host, defaults: defaults) else {
            return openExternally(url, reason: "host whitelist miss")
        }
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults),
              let sourcePanelId = request.sourcePanelId,
              let container else {
            return openExternally(url, reason: "source container unavailable")
        }

        log(
            "link.openURL target=embedded host=\(host) url=\(url) " +
            "container=\(container.terminalLinkContainerDebugName) surfaceId=\(sourcePanelId)"
        )

        deferOperation { [self] in
            let currentContainer = self.containerResolver(
                request.sourceWorkspaceId,
                sourcePanelId
            )
            let openedInBrowser = BrowserAvailabilitySettings.isEnabled(defaults: self.defaults)
                && currentContainer?.openTerminalBrowserLink(
                    url: url,
                    sourcePanelId: sourcePanelId
                ) == true
            if openedInBrowser { return }

            self.log(
                "link.openURL embedded open failed, opening externally " +
                "host=\(host) surfaceId=\(sourcePanelId) url=\(url)"
            )
            if !self.externalOpen(url) {
                NSSound.beep()
            }
        }
        return true
    }

    private func resolvedWorkingDirectory(
        request: TerminalLinkOpenRequest,
        container: (any TerminalLinkOpenContainer)?
    ) -> String? {
        if let reported = request.workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !reported.isEmpty {
            return reported
        }
        guard let sourcePanelId = request.sourcePanelId else { return nil }
        return container?.terminalLinkWorkingDirectory(for: sourcePanelId)
    }

    private func openExternally(_ url: URL, reason: String) -> Bool {
        log("link.openURL opening externally reason=\(reason) url=\(url)")
        return externalOpen(url)
    }

    private static func resolveContainer(
        sourceWorkspaceId: UUID?,
        sourcePanelId: UUID?
    ) -> (any TerminalLinkOpenContainer)? {
        guard let sourcePanelId else { return nil }
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(sourcePanelId) }) {
            return dock
        }
        guard let app = AppDelegate.shared else { return nil }
        return app.workspaceContainingPanel(
            panelId: sourcePanelId,
            preferredWorkspaceId: sourceWorkspaceId
        )?.workspace
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        cmuxDebugLog(message())
        #endif
    }
}
