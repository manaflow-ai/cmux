import CmuxControlSocket
import CmuxSettings
import CmuxSidebar
import CmuxSwiftRenderUI
import Foundation

/// App-side wiring for the worker-lane `sidebar.custom.*` control commands.
///
/// The command bodies live in CmuxControlSocket's ``ControlSidebarCustomWorker``;
/// this file supplies the live-state seam (``ControlSidebarCustomReading``) the
/// worker reads through, plus the one worker-thread→async bridge that lets the
/// synchronous `nonisolated` socket-worker lane drive the `async` worker.
///
/// ## Why the seam, not a direct call
///
/// `ControlSidebarCustomWorker` is in a package that must not import the
/// `CmuxSwiftRenderUI` validator / reload notification or the app target's
/// `CmuxExtensionSidebarSelection` / `SettingCatalog`. ``ControlSidebarCustomReading``
/// inverts that: the package owns the protocol, ``TerminalControllerSidebarCustomReading``
/// conforms it. Validation runs on the worker thread (the legacy bodies were
/// `nonisolated` and ran the SwiftUI-interpreter validation off-main); the
/// reload/select side effects hop to the main actor inside the conformer,
/// matching the legacy `v2MainSync` blocks exactly.
extension TerminalController {
    /// Drives the package ``ControlSidebarCustomWorker`` for one decoded
    /// `sidebar.custom.*` request from the synchronous socket-worker lane,
    /// blocking the worker thread until the async worker completes. This single
    /// semaphore is the worker-thread→async bridge (the legacy bodies blocked
    /// the worker lane on `v2MainSync` for their main-side side effects). The
    /// worker only returns `nil` for non-`sidebar.custom.*` methods, which the
    /// dispatcher never routes here, so a `nil` result reports the same
    /// encode-failure response the legacy plumbing produced for an impossible
    /// payload.
    nonisolated func runSidebarCustomWorker(_ request: ControlRequest) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ControlCallResult?
        Task {
            result = await controlSidebarCustomWorker.handle(request)
            semaphore.signal()
        }
        semaphore.wait()
        guard let result else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }
}

/// Conforms ``ControlSidebarCustomReading`` with no live app state: the bodies
/// reach only the static `CmuxExtensionSidebarSelection` sidebars directory /
/// provider, the `CmuxSwiftRenderUI` validator, and the `SettingCatalog`
/// beta-feature key, so the conformer is a plain `Sendable` value.
///
/// Validation runs on the calling worker thread (the heavy SwiftUI-interpreter
/// work the legacy `nonisolated` bodies kept off the main actor). The reload /
/// select side effects hop to the main actor via `MainActor.run`, reproducing
/// the legacy `v2MainSync` blocks (the notification post, the beta-feature flag
/// write, and the provider selection).
struct TerminalControllerSidebarCustomReading: ControlSidebarCustomReading {
    func strings() -> ControlSidebarCustomStrings {
        ControlSidebarCustomStrings(
            invalidName: String(
                localized: "socket.sidebar.custom.invalidName",
                defaultValue: "Sidebar name must not be empty."
            ),
            selectMissingName: String(
                localized: "socket.sidebar.custom.selectMissingName",
                defaultValue: "Select requires a sidebar name."
            )
        )
    }

    func validate(name: String?) -> ControlSidebarCustomReport {
        reportSnapshot(validationReport(name: name))
    }

    func reload(name: String?) async -> ControlSidebarCustomReport {
        let report = validationReport(name: name)
        let reloadNames = report.names
        if !reloadNames.isEmpty {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .customSidebarReloadRequested,
                    object: nil,
                    userInfo: ["names": reloadNames]
                )
            }
        }
        return reportSnapshot(report)
    }

    func select(name: String) async -> ControlSidebarCustomSelectOutcome {
        let report = validationReport(name: name)
        guard let entry = report.entries.first else {
            return .report(reportSnapshot(report))
        }
        if let errorMessage = entry.errorMessage {
            return .entryError(reportSnapshot(report), message: errorMessage)
        }

        let providerId = CmuxExtensionSidebarSelection.customSidebarProviderPrefix + name
        await MainActor.run {
            UserDefaults.standard.set(true, forKey: SettingCatalog().betaFeatures.customSidebars.userDefaultsKey)
            CmuxExtensionSidebarSelection().setProviderId(providerId)
            NotificationCenter.default.post(
                name: .customSidebarReloadRequested,
                object: nil,
                userInfo: ["names": [name]]
            )
        }
        return .selected(reportSnapshot(report), providerID: providerId, name: name)
    }

    // MARK: - Helpers

    /// Runs the `CustomSidebarValidator` against the custom-sidebars directory
    /// (the byte-faithful twin of the former `v2CustomSidebarValidationReport`).
    private func validationReport(name: String?) -> CustomSidebarValidationReport {
        let directory = CmuxExtensionSidebarSelection().customSidebarsDirectory
        return CustomSidebarValidator().validate(directory: directory, name: name)
    }

    /// Converts the app validation report to its Sendable control snapshot (the
    /// directory + per-sidebar entries the `v2CustomSidebarReportPayload` shaped
    /// onto the wire).
    private func reportSnapshot(_ report: CustomSidebarValidationReport) -> ControlSidebarCustomReport {
        ControlSidebarCustomReport(
            directoryPath: CmuxExtensionSidebarSelection().customSidebarsDirectory.path,
            entries: report.entries.map { entry in
                ControlSidebarCustomReportEntry(
                    name: entry.name,
                    path: entry.fileURL.path,
                    kindRawValue: entry.kind.rawValue,
                    isValid: entry.isValid,
                    errorMessage: entry.errorMessage
                )
            }
        )
    }
}
