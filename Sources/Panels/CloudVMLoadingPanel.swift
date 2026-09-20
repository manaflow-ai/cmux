import AppKit
import Combine
import Foundation

@MainActor
final class CloudVMLoadingPanel: Panel {
    enum Phase {
        case loading
        case failed(String, elapsedSeconds: Int)
    }

    let id: UUID
    let workspaceId: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .cloudVMLoading
    @Published var startedAt: Date
    @Published var phase: Phase = .loading
    /// Optional operation text for a Cloud workspace reservation. Base
    /// provisioning leaves this nil and keeps the existing status card.
    @Published var loadingHeadline: String? = nil

    var displayTitle: String {
        String(localized: "panel.cloudVM.loading.title", defaultValue: "Cloud VM")
    }

    var displayIcon: String? { "cloud.fill" }

    init(id: UUID = UUID(), workspaceId: UUID, startedAt: Date = Date()) {
        self.id = id
        self.workspaceId = workspaceId
        self.startedAt = startedAt
    }

    func configureLoadingHeadline(_ headline: String) {
        loadingHeadline = headline
    }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}

    func showFailure(_ message: String) {
        let trimmed = Self.presentableFailureMessage(from: message)
        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt).rounded(.down)))
        phase = .failed(trimmed.isEmpty
            ? String(localized: "panel.cloudVM.loading.failed.generic", defaultValue: "Cloud VM could not be opened.")
            : trimmed,
            elapsedSeconds: elapsedSeconds
        )
    }

    var hasFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    func resetLoading() {
        startedAt = Date()
        phase = .loading
        loadingHeadline = nil
    }

    private static func presentableFailureMessage(from rawMessage: String) -> String {
        let cleaned = rawMessage
            .replacingOccurrences(of: "\u{001B}[2K", with: "")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(of: #"\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        let joined = cleaned.joined(separator: "\n")
        let lowercased = joined.lowercased()

        if lowercased.contains("local cmux web server") || lowercased.contains("localhost:") || lowercased.contains("127.0.0.1:") {
            return String(
                localized: "panel.cloudVM.loading.failed.localServer",
                defaultValue: "The local cmux web server is offline. Start it and retry Open Cloud VM."
            )
        }
        if lowercased.contains("waiting for the cloud vm service")
            || lowercased.contains("vm_cloud_service_unavailable")
            || lowercased.contains("http 502")
            || lowercased.contains("http 503")
            || lowercased.contains("service unavailable") {
            return String(
                localized: "panel.cloudVM.loading.failed.serviceUnavailable",
                defaultValue: "The Cloud VM service could not create a VM yet. Retry keeps using this pinned Cloud VM slot, and once a VM exists cmux will always reattach to that same VM."
            )
        }
        if lowercased.contains("password") || lowercased.contains("permission denied") {
            return String(
                localized: "panel.cloudVM.loading.failed.auth",
                defaultValue: "cmux could not open a passwordless terminal session. Try opening the Cloud VM again."
            )
        }

        var seen = Set<String>()
        let collapsed = cleaned.filter { line in
            let key = line.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return !key.contains("created cloud vm")
                && !key.contains("[cmux]")
                && !key.contains("freestyle")
                && !key.contains("provider")
                && !key.contains("http://")
                && !key.contains("https://")
        }
        return String(collapsed.joined(separator: "\n").prefix(600))
    }
}
