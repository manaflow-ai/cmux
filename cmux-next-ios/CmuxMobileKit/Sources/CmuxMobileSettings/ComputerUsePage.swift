#if os(iOS)
import CmuxDeviceHub
import CmuxMobileDesign
import CmuxMobileScreenSharing
import OSLog
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard
private let log = Logger(subsystem: "dev.cmux.mobile", category: "computer-use")

/// Settings → Computer Use (docs/computer-use-approvals.md, "Device hub approvals"): this
/// iPhone's approval key fingerprint, the one a box owner compares when
/// `cmux computer-use setup --approver` pins this iPhone (same digits, same grouping).
struct ComputerUsePage: View {
    /// The running hub, whose identity holds the approval key (nil in mock mode or before it loads).
    let screenSharing: ScreenSharingService?
    @State private var approvalKey: ComputerUseApprovalKeyRow.Status = .loading

    var body: some View {
        List {
            Section {
                ComputerUseApprovalKeyRow(state: approvalKey)
            } footer: {
                Text(ComputerUseStrings.compare)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, theme.metrics.settingsRowHeight)
        .scrollContentBackground(.hidden)
        .background(theme.colors.bgGrouped.color.ignoresSafeArea())
        .navigationTitle(ComputerUseStrings.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: screenSharing?.hub?.identity.id) { approvalKey = await load() }
    }

    /// The hub's identity when it runs, else this app's identity from the Keychain (the same
    /// approval key: the hub registers the one kept there).
    private func load() async -> ComputerUseApprovalKeyRow.Status {
        if let identity = screenSharing?.hub?.identity { return .init(identity.approvalKeyDisplayFingerprint) }
        let bundle = Bundle.main.bundleIdentifier ?? "dev.cmux.mobile"
        do {
            let identity = try await Task.detached(priority: .userInitiated) {
                try DeviceIdentity.forApp(bundleIdentifier: bundle, approvalKeys: .platform)
            }.value
            return .init(identity.approvalKeyDisplayFingerprint)
        } catch {
            log.error("computer use settings: this phone's identity did not load: \(String(describing: error), privacy: .public)")
            return .missing
        }
    }
}

/// "Approval key" over its fingerprint (monospaced, in the groups setup prints), copyable
/// from its context menu; "No approval key" when this iPhone has none.
struct ComputerUseApprovalKeyRow: View {
    enum Status: Equatable {
        case loading
        case missing
        case key(String)

        init(_ display: String?) { self = display.map(Status.key) ?? .missing }
    }

    let state: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ComputerUseStrings.approvalKey)
                .font(theme.type.rowTitle)
                .foregroundStyle(theme.colors.label)
            switch state {
            case .loading:
                Text(ComputerUseStrings.loading).font(theme.type.meta).foregroundStyle(theme.colors.label2)
            case .missing:
                Text(ComputerUseStrings.noApprovalKey).font(theme.type.meta).foregroundStyle(theme.colors.label2)
            case let .key(fingerprint):
                Text(verbatim: fingerprint)
                    .font(theme.type.codeBody)
                    .foregroundStyle(theme.colors.label2)
                    .accessibilityIdentifier("settings.computerUse.approvalKey.fingerprint")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.computerUse.approvalKey")
        .contextMenu {
            if case let .key(fingerprint) = state {
                Button(ComputerUseStrings.copy, systemImage: "doc.on.doc") { UIPasteboard.general.string = fingerprint }
            }
        }
    }
}

/// Settings → Computer Use copy (Localizable.xcstrings, `mobile.computerUse.*`).
struct ComputerUseStrings {
    static var title: String { String(localized: "mobile.computerUse.title", defaultValue: "Computer Use", bundle: .module) }
    static var approvalKey: String { String(localized: "mobile.computerUse.approvalKey", defaultValue: "Approval key", bundle: .module) }
    static var noApprovalKey: String {
        String(localized: "mobile.computerUse.noApprovalKey", defaultValue: "No approval key", bundle: .module)
    }
    static var loading: String { String(localized: "mobile.computerUse.loading", defaultValue: "Loading…", bundle: .module) }
    static var compare: String {
        String(localized: "mobile.computerUse.compare", defaultValue: "Compare this when you pin this iPhone on a computer.", bundle: .module)
    }
    static var copy: String { String(localized: "mobile.computerUse.copy", defaultValue: "Copy", bundle: .module) }
}
#endif
