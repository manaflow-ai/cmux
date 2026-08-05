#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import Foundation
import Observation
import UIKit

/// Native UIKit editor for relay policy, private paths, and safe diagnostics.
@MainActor
final class MobileIrohSettingsViewController: UITableViewController {
    private enum Row: Hashable {
        case preferenceAutomatic
        case preferenceManaged
        case preferenceCustom
        case managedRelay(String)
        case relayOnly
        case customRelay(String)
        case addCustomRelay
        case privatePath(String)
        case addPrivatePath
        #if DEBUG
        case debugTransport(CmxIrohTransportVerificationMode)
        #endif
        case connectionStatus
        case policyStatus
        case lastSuccess
        case lastFailure
        case failureTime
        case eventCount
        case attention
        case refresh
        case shareReport
        case verboseLog
        case shareVerboseLog
        case clearReport
    }

    private struct Section {
        let title: String?
        let footer: String?
        let rows: [Row]
    }

    private let model: MobileIrohSettingsModel
    private var sections: [Section] = []
    private var observationTask: Task<Void, Never>?

    init(controller: any CmxIrohSettingsControlling) {
        model = MobileIrohSettingsModel(controller: controller)
        super.init(style: .insetGrouped)
        title = L10n.string("mobile.iroh.title", defaultValue: "Iroh and Relays")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observationTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "MobileIrohSettings"
        rebuildSectionsAndTrackChanges()
        observationTask = Task { [weak model] in
            await model?.observe()
        }
    }

    private func rebuildSectionsAndTrackChanges() {
        withObservationTracking {
            rebuildSections()
            _ = model.snapshot
            _ = model.isMutating
            _ = model.showsSaveError
            _ = model.testResults
            _ = model.diagnosticReport
            _ = model.diagnosticExportText
            _ = model.verboseLogEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                rebuildSectionsAndTrackChanges()
                if model.showsSaveError { presentSaveError() }
            }
        }
    }

    private func rebuildSections() {
        let snapshot = model.snapshot
        var result = [Section(
            title: L10n.string("mobile.iroh.relays", defaultValue: "Iroh Relays"),
            footer: L10n.string(
                "mobile.iroh.relays.footer",
                defaultValue: "Direct peer-to-peer stays enabled. cmux verifies a signed relay catalog, so fleet changes do not require an app update."
            ),
            rows: [.preferenceAutomatic, .preferenceManaged, .preferenceCustom]
                + (preferenceChoice == .managed
                    ? snapshot.managedRelays.map { .managedRelay($0.id) }
                    : [])
        )]
        result.append(Section(
            title: nil,
            footer: L10n.string(
                "mobile.iroh.relayOnly.footer",
                defaultValue: "Keeps this device's Iroh connections on cmux relays instead of direct or local-network paths. Applies on the next reconnect."
            ),
            rows: [.relayOnly]
        ))
        result.append(Section(
            title: L10n.string("mobile.iroh.custom", defaultValue: "Custom Relays"),
            footer: L10n.string(
                "mobile.iroh.custom.footer",
                defaultValue: "Addresses sync with your account. Provider secrets stay in this device's Keychain. A missing secret never enables another relay provider."
            ),
            rows: snapshot.customRelays.map { .customRelay($0.id) } + [.addCustomRelay]
        ))
        result.append(Section(
            title: L10n.string("mobile.iroh.private.custom", defaultValue: "Private Network Paths"),
            footer: L10n.string(
                "mobile.iroh.private.custom.footer",
                defaultValue: "Numeric private addresses stay on this device and use the Mac's broker-authenticated Iroh identity."
            ),
            rows: snapshot.customPrivateNetworks.map { .privatePath($0.macDeviceID) }
                + (availablePrivatePathMacs.isEmpty ? [] : [.addPrivatePath])
        ))
        #if DEBUG
        if snapshot.debugTransportVerificationMode != nil {
            result.append(Section(
                title: L10n.string("mobile.iroh.debug", defaultValue: "Debug Verification"),
                footer: L10n.string(
                    "mobile.iroh.debug.footer",
                    defaultValue: "Changing this restarts Iroh without signing out or changing this app's device identity."
                ),
                rows: CmxIrohTransportVerificationMode.allCases.map { .debugTransport($0) }
            ))
        }
        #endif
        var diagnosticRows: [Row] = [
            .connectionStatus, .policyStatus, .lastSuccess, .lastFailure, .failureTime, .eventCount,
        ]
        if needsAttention { diagnosticRows.append(.attention) }
        diagnosticRows += [.refresh, .shareReport, .verboseLog]
        if model.verboseLogShareURL != nil { diagnosticRows.append(.shareVerboseLog) }
        diagnosticRows.append(.clearReport)
        result.append(Section(
            title: L10n.string("mobile.iroh.diagnostics", defaultValue: "Diagnostics"),
            footer: L10n.string(
                "mobile.iroh.diagnostics.privacy",
                defaultValue: "This report remains available while disconnected. It excludes terminal content, account and endpoint identities, network addresses, relay URLs, credentials, and raw errors. Nothing leaves this device until you share it."
            ),
            rows: diagnosticRows
        ))
        sections = result
        tableView.isUserInteractionEnabled = !model.isMutating
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .default
        switch row {
        case .preferenceAutomatic:
            configureChoice(cell, title: L10n.string("mobile.iroh.preference.automatic", defaultValue: "Automatic"), selected: preferenceChoice == .automatic)
            cell.accessibilityIdentifier = "MobileIrohRelayPreference-Automatic"
        case .preferenceManaged:
            configureChoice(cell, title: L10n.string("mobile.iroh.preference.managed", defaultValue: "Selected cmux Relays"), selected: preferenceChoice == .managed)
            cell.accessibilityIdentifier = "MobileIrohRelayPreference-Managed"
        case .preferenceCustom:
            configureChoice(cell, title: L10n.string("mobile.iroh.preference.custom", defaultValue: "Custom Relays"), selected: preferenceChoice == .custom)
            cell.accessibilityIdentifier = "MobileIrohRelayPreference-Custom"
        case .managedRelay(let id):
            if let relay = model.snapshot.managedRelays.first(where: { $0.id == id }) {
                cell.textLabel?.text = relay.region
                cell.detailTextLabel?.text = relay.provider
                cell.accessoryType = relay.isSelected ? .checkmark : .none
                cell.accessibilityIdentifier = "MobileIrohManagedRelay-\(id)"
            }
        case .relayOnly:
            configureSwitch(
                cell,
                title: L10n.string("mobile.iroh.relayOnly", defaultValue: "Relay Only"),
                identifier: "MobileIrohRelayOnly",
                isOn: model.snapshot.pathPreference == .relayOnly
            ) { [weak self] enabled in
                self?.model.setPathPreference(enabled ? .relayOnly : .automatic)
            }
        case .customRelay(let id):
            if let relay = model.snapshot.customRelays.first(where: { $0.id == id }) {
                cell.textLabel?.text = relay.displayName
                cell.detailTextLabel?.text = customRelaySubtitle(relay)
                cell.accessoryType = .disclosureIndicator
                cell.accessibilityIdentifier = "MobileIrohCustomRelay-\(id)"
            }
        case .addCustomRelay:
            configureAction(cell, title: L10n.string("mobile.iroh.custom.add", defaultValue: "Add Custom Relay"), symbol: "plus", identifier: "MobileIrohAddCustomRelay")
        case .privatePath(let macDeviceID):
            if let path = model.snapshot.customPrivateNetworks.first(where: { $0.macDeviceID == macDeviceID }) {
                cell.textLabel?.text = displayName(path.macDisplayName)
                cell.detailTextLabel?.text = path.addresses.joined(separator: ", ")
                cell.accessoryType = path.isEnabled ? .checkmark : .disclosureIndicator
                cell.accessibilityIdentifier = "MobileIrohPrivatePath-\(macDeviceID)"
            }
        case .addPrivatePath:
            configureAction(cell, title: L10n.string("mobile.iroh.private.custom.add", defaultValue: "Add Private Addresses"), symbol: "plus", identifier: "MobileIrohAddPrivatePath")
        #if DEBUG
        case .debugTransport(let mode):
            configureChoice(cell, title: debugTransportTitle(mode), selected: model.snapshot.debugTransportVerificationMode == mode)
            cell.accessibilityIdentifier = "MobileIrohDebugTransportMode-\(mode.rawValue)"
        #endif
        case .connectionStatus:
            configureValue(cell, title: L10n.string("mobile.iroh.status", defaultValue: "Connection"), value: runtimeStatusText)
        case .policyStatus:
            configureValue(cell, title: L10n.string("mobile.iroh.policy", defaultValue: "Relay Policy"), value: policyStatusText)
        case .lastSuccess:
            configureValue(cell, title: L10n.string("mobile.iroh.diagnostics.lastSuccess", defaultValue: "Last Successful Connection"), value: diagnosticDate(model.diagnosticReport.lastConnectionSuccessDate))
        case .lastFailure:
            configureValue(cell, title: L10n.string("mobile.iroh.diagnostics.lastFailure", defaultValue: "Last Failure"), value: diagnosticFailureKindText)
        case .failureTime:
            configureValue(cell, title: L10n.string("mobile.iroh.diagnostics.lastFailureTime", defaultValue: "Failure Time"), value: diagnosticDate(model.diagnosticReport.lastFailureDate))
        case .eventCount:
            configureValue(cell, title: L10n.string("mobile.iroh.diagnostics.eventCount", defaultValue: "Recorded Events"), value: model.diagnosticReport.events.count.formatted())
        case .attention:
            cell.textLabel?.text = L10n.string("mobile.iroh.attention", defaultValue: "Your relay preference needs attention. cmux is keeping an unselected provider disabled.")
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.textColor = .systemOrange
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle.fill")
            cell.imageView?.tintColor = .systemOrange
            cell.selectionStyle = .none
        case .refresh:
            configureAction(cell, title: L10n.string("mobile.iroh.refresh", defaultValue: "Refresh Relay Policy"), symbol: "arrow.clockwise", identifier: "MobileIrohRefresh")
        case .shareReport:
            configureAction(cell, title: L10n.string("mobile.iroh.diagnostics.share", defaultValue: "Share Safe Report"), symbol: "square.and.arrow.up", identifier: "MobileIrohShareDiagnosticReport")
            cell.isUserInteractionEnabled = !model.diagnosticExportText.isEmpty
            cell.textLabel?.textColor = model.diagnosticExportText.isEmpty ? .tertiaryLabel : .label
        case .verboseLog:
            configureSwitch(
                cell,
                title: L10n.string("mobile.iroh.diagnostics.verboseLog", defaultValue: "Verbose Connection Log"),
                identifier: "MobileIrohVerboseLogToggle",
                isOn: model.verboseLogEnabled
            ) { [weak self] enabled in
                guard let self else { return }
                Task { await model.setVerboseLog(enabled) }
            }
        case .shareVerboseLog:
            configureAction(cell, title: L10n.string("mobile.iroh.diagnostics.shareVerboseLog", defaultValue: "Share Verbose Log"), symbol: "doc.text", identifier: "MobileIrohShareVerboseLog")
        case .clearReport:
            configureAction(cell, title: L10n.string("mobile.iroh.diagnostics.clear", defaultValue: "Clear Report"), symbol: "trash", identifier: "MobileIrohClearDiagnosticReport")
            cell.textLabel?.textColor = model.diagnosticReport.events.isEmpty ? .tertiaryLabel : .systemRed
            cell.imageView?.tintColor = model.diagnosticReport.events.isEmpty ? .tertiaryLabel : .systemRed
            cell.isUserInteractionEnabled = !model.diagnosticReport.events.isEmpty
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .preferenceAutomatic:
            model.setPreference(.automatic)
        case .preferenceManaged:
            let selected = Set(model.snapshot.managedRelays.filter(\.isSelected).map(\.id))
            let all = Set(model.snapshot.managedRelays.map(\.id))
            guard !all.isEmpty else { return }
            model.setPreference(.managed(selected.isEmpty ? all : selected))
        case .preferenceCustom:
            model.setPreference(.custom)
        case .managedRelay(let id):
            toggleManagedRelay(id)
        case .customRelay(let id):
            presentCustomRelayActions(id: id, source: tableView.cellForRow(at: indexPath))
        case .addCustomRelay:
            presentCustomRelayEditor(relay: nil)
        case .privatePath(let macDeviceID):
            presentPrivatePathActions(macDeviceID: macDeviceID, source: tableView.cellForRow(at: indexPath))
        case .addPrivatePath:
            presentPrivatePathEditor(path: nil)
        #if DEBUG
        case .debugTransport(let mode):
            model.setDebugTransportVerificationMode(mode)
        #endif
        case .refresh:
            model.refresh()
        case .shareReport:
            share(items: [model.diagnosticExportText], source: tableView.cellForRow(at: indexPath))
        case .shareVerboseLog:
            if let url = model.verboseLogShareURL { share(items: [url], source: tableView.cellForRow(at: indexPath)) }
        case .clearReport:
            confirmClearReport()
        default:
            break
        }
    }

    private func configureChoice(_ cell: UITableViewCell, title: String, selected: Bool) {
        cell.textLabel?.text = title
        cell.accessoryType = selected ? .checkmark : .none
    }

    private func configureValue(_ cell: UITableViewCell, title: String, value: String) {
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = value
        cell.selectionStyle = .none
    }

    private func configureAction(_ cell: UITableViewCell, title: String, symbol: String, identifier: String) {
        cell.textLabel?.text = title
        cell.imageView?.image = UIImage(systemName: symbol)
        cell.accessibilityIdentifier = identifier
    }

    private func configureSwitch(
        _ cell: UITableViewCell,
        title: String,
        identifier: String,
        isOn: Bool,
        changed: @escaping @MainActor (Bool) -> Void
    ) {
        cell.textLabel?.text = title
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = identifier
        let control = UISwitch()
        control.isOn = isOn
        control.addAction(UIAction { action in
            guard let control = action.sender as? UISwitch else { return }
            MainActor.assumeIsolated { changed(control.isOn) }
        }, for: .valueChanged)
        cell.accessoryView = control
    }

    private enum PreferenceChoice { case automatic, managed, custom }

    private var preferenceChoice: PreferenceChoice {
        switch model.snapshot.preference {
        case .automatic: .automatic
        case .managed: .managed
        case .custom: .custom
        }
    }

    private func toggleManagedRelay(_ id: String) {
        var selected = Set(model.snapshot.managedRelays.filter(\.isSelected).map(\.id))
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        guard !selected.isEmpty else { return }
        model.setPreference(.managed(selected))
    }

    private func presentCustomRelayActions(id: String, source: UIView?) {
        guard let relay = model.snapshot.customRelays.first(where: { $0.id == id }) else { return }
        let alert = UIAlertController(title: relay.displayName, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: L10n.string("mobile.iroh.test", defaultValue: "Test Connection"), style: .default) { [weak self] _ in
            self?.model.testCustomRelay(id: id)
        })
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.edit", defaultValue: "Edit"), style: .default) { [weak self] _ in
            self?.presentCustomRelayEditor(relay: relay)
        })
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.remove", defaultValue: "Remove"), style: .destructive) { [weak self] _ in
            self?.model.removeCustomRelay(id: id)
        })
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        configurePopover(alert, source: source)
        present(alert, animated: true)
    }

    private func presentPrivatePathActions(macDeviceID: String, source: UIView?) {
        guard let path = model.snapshot.customPrivateNetworks.first(where: { $0.macDeviceID == macDeviceID }) else { return }
        let alert = UIAlertController(title: displayName(path.macDisplayName), message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: path.isEnabled
            ? L10n.string("mobile.common.disable", defaultValue: "Disable")
            : L10n.string("mobile.common.enable", defaultValue: "Enable"), style: .default) { [weak self] _ in
                guard let self else { return }
                Task {
                    _ = await model.upsertCustomPrivatePath(CmxIrohCustomPrivatePathDraft(
                        macDeviceID: path.macDeviceID,
                        macDisplayName: path.macDisplayName,
                        addresses: path.addresses,
                        isEnabled: !path.isEnabled
                    ))
                }
            })
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.edit", defaultValue: "Edit"), style: .default) { [weak self] _ in
            self?.presentPrivatePathEditor(path: path)
        })
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.remove", defaultValue: "Remove"), style: .destructive) { [weak self] _ in
            self?.model.removeCustomPrivatePath(macDeviceID: macDeviceID)
        })
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        configurePopover(alert, source: source)
        present(alert, animated: true)
    }

    private func presentCustomRelayEditor(relay: CmxIrohSettingsSnapshot.CustomRelay?) {
        let editor = MobileIrohCustomRelayEditorViewController(relay: relay) { [weak model] draft, secret in
            guard let model else { return false }
            return await model.upsertCustomRelay(draft, deviceSecret: secret)
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    private func presentPrivatePathEditor(path: CmxIrohSettingsSnapshot.CustomPrivateNetwork?) {
        let editor = MobileIrohPrivatePathEditorViewController(
            path: path,
            availableMacs: path.map { [.init(id: $0.macDeviceID, displayName: $0.macDisplayName)] }
                ?? availablePrivatePathMacs
        ) { [weak model] draft in
            guard let model else { return false }
            return await model.upsertCustomPrivatePath(draft)
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    private var availablePrivatePathMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac] {
        let configured = Set(model.snapshot.customPrivateNetworks.map(\.macDeviceID))
        return model.snapshot.privateNetworkMacs.filter { !configured.contains($0.id) }
    }

    private func presentSaveError() {
        guard presentedViewController == nil else { return }
        model.clearSaveError()
        let alert = UIAlertController(
            title: L10n.string("mobile.iroh.saveFailed", defaultValue: "Could Not Save Networking Settings"),
            message: L10n.string("mobile.iroh.saveFailed.message", defaultValue: "Your previous networking configuration is still active. Check the values, then try again."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func confirmClearReport() {
        let alert = UIAlertController(
            title: L10n.string("mobile.iroh.diagnostics.clear.confirm", defaultValue: "Clear this diagnostic report?"),
            message: L10n.string("mobile.iroh.diagnostics.clear.message", defaultValue: "This permanently removes the connection timeline stored on this device."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("mobile.iroh.diagnostics.clear", defaultValue: "Clear Report"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { await model.clearDiagnosticReport() }
        })
        present(alert, animated: true)
    }

    private func share(items: [Any], source: UIView?) {
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        configurePopover(activity, source: source)
        present(activity, animated: true)
    }

    private func configurePopover(_ controller: UIViewController, source: UIView?) {
        guard let popover = controller.popoverPresentationController else { return }
        popover.sourceView = source ?? view
        popover.sourceRect = source?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    }

    private var needsAttention: Bool {
        !model.snapshot.staleRelayIDs.isEmpty || model.snapshot.failureDescription != nil
    }

    private func customRelaySubtitle(_ relay: CmxIrohSettingsSnapshot.CustomRelay) -> String {
        switch model.testResults[relay.id] {
        case .reachable:
            L10n.string("mobile.iroh.test.reachable", defaultValue: "Reachable")
        case .failed:
            L10n.string("mobile.iroh.test.failed", defaultValue: "Unreachable")
        case .incomplete:
            L10n.string("mobile.iroh.test.incomplete", defaultValue: "Test Unavailable")
        case nil:
            String(format: L10n.string("mobile.iroh.custom.summary", defaultValue: "%1$@ · %2$@"), relay.provider, relay.region)
        }
    }

    private var runtimeStatusText: String {
        switch model.snapshot.runtimeStatus {
        case .inactive: L10n.string("mobile.iroh.status.inactive", defaultValue: "Inactive")
        case .starting: L10n.string("mobile.iroh.status.starting", defaultValue: "Starting")
        case .active: L10n.string("mobile.iroh.status.active", defaultValue: "Iroh Active")
        case .direct: L10n.string("mobile.iroh.status.direct", defaultValue: "Direct Peer-to-Peer")
        case .relayed: L10n.string("mobile.iroh.status.relayed", defaultValue: "Relayed")
        case .privateNetwork: L10n.string("mobile.iroh.status.private", defaultValue: "Private Network")
        case .degraded: L10n.string("mobile.iroh.status.degraded", defaultValue: "Direct-Only")
        }
    }

    private var policyStatusText: String {
        switch model.snapshot.policySource {
        case .server: L10n.string("mobile.iroh.policy.server", defaultValue: "Verified from cmux")
        case .cached: L10n.string("mobile.iroh.policy.cached", defaultValue: "Last Verified Catalog")
        case .unavailable: L10n.string("mobile.iroh.policy.unavailable", defaultValue: "Unavailable")
        }
    }

    private func diagnosticDate(_ date: Date?) -> String {
        guard let date else { return L10n.string("mobile.iroh.diagnostics.notRecorded", defaultValue: "Not Recorded") }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private var diagnosticFailureKindText: String {
        switch model.diagnosticReport.lastFailureKind {
        case nil, .some(.none): L10n.string("mobile.iroh.diagnostics.failure.none", defaultValue: "None")
        case .some(.offline): L10n.string("mobile.iroh.diagnostics.failure.offline", defaultValue: "Offline")
        case .some(.timedOut): L10n.string("mobile.iroh.diagnostics.failure.timedOut", defaultValue: "Timed Out")
        case .some(.transportIdleTimedOut): L10n.string("mobile.iroh.diagnostics.failure.transportIdleTimedOut", defaultValue: "Transport Idle Timeout")
        case .some(.connectionRefused): L10n.string("mobile.iroh.diagnostics.failure.connectionRefused", defaultValue: "Connection Refused")
        case .some(.hostUnreachable): L10n.string("mobile.iroh.diagnostics.failure.hostUnreachable", defaultValue: "Host Unreachable")
        case .some(.permissionDenied): L10n.string("mobile.iroh.diagnostics.failure.permissionDenied", defaultValue: "Permission Denied")
        case .some(.dnsFailed): L10n.string("mobile.iroh.diagnostics.failure.dnsFailed", defaultValue: "Name Resolution Failed")
        case .some(.secureChannelFailed): L10n.string("mobile.iroh.diagnostics.failure.secureChannelFailed", defaultValue: "Secure Channel Failed")
        case .some(.unsupportedRoute): L10n.string("mobile.iroh.diagnostics.failure.unsupportedRoute", defaultValue: "Unsupported Route")
        case .some(.noRoute): L10n.string("mobile.iroh.diagnostics.failure.noRoute", defaultValue: "No Route Available")
        case .some(.credentialUnavailable): L10n.string("mobile.iroh.diagnostics.failure.credentialUnavailable", defaultValue: "Credentials Unavailable")
        case .some(.policyUnavailable): L10n.string("mobile.iroh.diagnostics.failure.policyUnavailable", defaultValue: "Relay Policy Unavailable")
        case .some(.endpointUnavailable): L10n.string("mobile.iroh.diagnostics.failure.endpointUnavailable", defaultValue: "Endpoint Unavailable")
        case .some(.identityMismatch): L10n.string("mobile.iroh.diagnostics.failure.identityMismatch", defaultValue: "Endpoint Identity Mismatch")
        case .some(.admissionDenied): L10n.string("mobile.iroh.diagnostics.failure.admissionDenied", defaultValue: "Connection Admission Denied")
        case .some(.admissionLeaseExpired): L10n.string("mobile.iroh.diagnostics.failure.admissionLeaseExpired", defaultValue: "Admission Lease Expired")
        case .some(.admissionRevalidationFailed): L10n.string("mobile.iroh.diagnostics.failure.admissionRevalidationFailed", defaultValue: "Admission Revalidation Failed")
        case .some(.authorizationFailed): L10n.string("mobile.iroh.diagnostics.failure.authorizationFailed", defaultValue: "Authorization Failed")
        case .some(.accountMismatch): L10n.string("mobile.iroh.diagnostics.failure.accountMismatch", defaultValue: "Account Mismatch")
        case .some(.protocolViolation): L10n.string("mobile.iroh.diagnostics.failure.protocolViolation", defaultValue: "Protocol Error")
        case .some(.connectionClosed): L10n.string("mobile.iroh.diagnostics.failure.connectionClosed", defaultValue: "Connection Closed")
        case .some(.sendQueueOverflow): L10n.string("mobile.iroh.diagnostics.failure.sendQueueOverflow", defaultValue: "Send Queue Overflow")
        case .some(.routeGated): L10n.string("mobile.iroh.diagnostics.failure.routeGated", defaultValue: "Route Gated")
        case .some(.superseded): L10n.string("mobile.iroh.diagnostics.failure.superseded", defaultValue: "Replaced by a Newer Attempt")
        case .some(.cancelled): L10n.string("mobile.iroh.diagnostics.failure.cancelled", defaultValue: "Cancelled")
        case .some(.unknown): L10n.string("mobile.iroh.diagnostics.failure.unknown", defaultValue: "Unknown")
        }
    }

    #if DEBUG
    private func debugTransportTitle(_ mode: CmxIrohTransportVerificationMode) -> String {
        switch mode {
        case .automatic: L10n.string("mobile.iroh.debug.transportMode.automatic", defaultValue: "Automatic")
        case .relayOnly: L10n.string("mobile.iroh.debug.transportMode.relayOnly", defaultValue: "Relay Only")
        case .directOnly: L10n.string("mobile.iroh.debug.transportMode.directOnly", defaultValue: "No Relay (Direct Only)")
        }
    }
    #endif

    private func displayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("mobile.iroh.private.custom.unnamedMac", defaultValue: "Mac") : trimmed
    }
}

@MainActor
private final class MobileIrohCustomRelayEditorViewController: UITableViewController {
    private enum Field: Int, CaseIterable { case name, provider, region, url, secret }

    private let existingID: String?
    private let onSave: (CmxIrohCustomRelayDraft, String?) async -> Bool
    private var values: [Field: String]
    private var authMode: CmxIrohCustomRelayCredentialMode
    private var isSaving = false

    init(
        relay: CmxIrohSettingsSnapshot.CustomRelay?,
        onSave: @escaping (CmxIrohCustomRelayDraft, String?) async -> Bool
    ) {
        existingID = relay?.id
        self.onSave = onSave
        values = [
            .name: relay?.displayName ?? "",
            .provider: relay?.provider ?? "",
            .region: relay?.region ?? "",
            .url: relay?.url ?? "https://",
            .secret: "",
        ]
        authMode = relay?.authMode ?? .none
        super.init(style: .insetGrouped)
        title = relay == nil
            ? L10n.string("mobile.iroh.custom.add", defaultValue: "Add Custom Relay")
            : L10n.string("mobile.iroh.custom.edit", defaultValue: "Edit Custom Relay")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("mobile.common.save", defaultValue: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() }
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 4 : (authMode == .deviceSecret ? 2 : 1)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        return L10n.string("mobile.iroh.custom.secret.note", defaultValue: "Relay secrets stay in this device's Keychain and do not sync with your account.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1, indexPath.row == 0 {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = L10n.string("mobile.iroh.custom.authentication", defaultValue: "Authentication")
            cell.detailTextLabel?.text = authMode == .none
                ? L10n.string("mobile.iroh.custom.authentication.none", defaultValue: "None")
                : L10n.string("mobile.iroh.custom.authentication.secret", defaultValue: "Device Secret")
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        let field: Field = indexPath.section == 0 ? Field(rawValue: indexPath.row)! : .secret
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholder = placeholder(for: field)
        textField.text = values[field]
        textField.tag = field.rawValue
        textField.clearButtonMode = .whileEditing
        textField.autocapitalizationType = field == .name ? .sentences : .none
        textField.autocorrectionType = .no
        textField.keyboardType = field == .url ? .URL : .default
        textField.isSecureTextEntry = field == .secret
        textField.addAction(UIAction { [weak self] action in
            guard let textField = action.sender as? UITextField,
                  let field = Field(rawValue: textField.tag) else { return }
            self?.values[field] = textField.text ?? ""
        }, for: .editingChanged)
        cell.contentView.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            textField.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            textField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
        ])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, indexPath.row == 0 else { return }
        let alert = UIAlertController(title: L10n.string("mobile.iroh.custom.authentication", defaultValue: "Authentication"), message: nil, preferredStyle: .actionSheet)
        for mode in [CmxIrohCustomRelayCredentialMode.none, .deviceSecret] {
            let title = mode == .none
                ? L10n.string("mobile.iroh.custom.authentication.none", defaultValue: "None")
                : L10n.string("mobile.iroh.custom.authentication.secret", defaultValue: "Device Secret")
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.authMode = mode
                self?.tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        alert.popoverPresentationController?.sourceRect = tableView.cellForRow(at: indexPath)?.bounds ?? .zero
        present(alert, animated: true)
    }

    private func placeholder(for field: Field) -> String {
        switch field {
        case .name: L10n.string("mobile.iroh.custom.name", defaultValue: "Name")
        case .provider: L10n.string("mobile.iroh.custom.provider", defaultValue: "Provider")
        case .region: L10n.string("mobile.iroh.custom.region", defaultValue: "Region")
        case .url: L10n.string("mobile.iroh.custom.url", defaultValue: "Relay URL")
        case .secret: existingID == nil
            ? L10n.string("mobile.iroh.custom.secret", defaultValue: "Relay Secret")
            : L10n.string("mobile.iroh.custom.secret.keep", defaultValue: "New Secret (optional)")
        }
    }

    private func save() {
        guard !isSaving else { return }
        let trimmed = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let name = trimmed[.name], !name.isEmpty,
              let provider = trimmed[.provider], !provider.isEmpty,
              let region = trimmed[.region], !region.isEmpty,
              let url = trimmed[.url], url.hasPrefix("https://"),
              authMode == .none || existingID != nil || !(trimmed[.secret] ?? "").isEmpty else {
            presentValidationError()
            return
        }
        isSaving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let draft = CmxIrohCustomRelayDraft(
            id: existingID,
            displayName: name,
            provider: provider,
            region: region,
            url: url,
            authMode: authMode
        )
        Task { [weak self] in
            guard let self else { return }
            let secret = trimmed[.secret].flatMap { $0.isEmpty ? nil : $0 }
            if await onSave(draft, secret) { dismiss(animated: true) }
            isSaving = false
            navigationItem.rightBarButtonItem?.isEnabled = true
        }
    }

    private func presentValidationError() {
        let alert = UIAlertController(
            title: L10n.string("mobile.iroh.saveFailed", defaultValue: "Could Not Save Networking Settings"),
            message: L10n.string("mobile.iroh.custom.validation", defaultValue: "Enter a name, provider, region, and HTTPS relay URL. A new authenticated relay also needs a device secret."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
    }
}

@MainActor
private final class MobileIrohPrivatePathEditorViewController: UITableViewController, UITextViewDelegate {
    private let existing: CmxIrohSettingsSnapshot.CustomPrivateNetwork?
    private let availableMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac]
    private let onSave: (CmxIrohCustomPrivatePathDraft) async -> Bool
    private var selectedMacDeviceID: String
    private var addressesText: String
    private var isEnabled: Bool
    private var isSaving = false

    init(
        path: CmxIrohSettingsSnapshot.CustomPrivateNetwork?,
        availableMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac],
        onSave: @escaping (CmxIrohCustomPrivatePathDraft) async -> Bool
    ) {
        existing = path
        self.availableMacs = availableMacs
        self.onSave = onSave
        selectedMacDeviceID = path?.macDeviceID ?? availableMacs.first?.id ?? ""
        addressesText = path?.addresses.joined(separator: "\n") ?? ""
        isEnabled = path?.isEnabled ?? false
        super.init(style: .insetGrouped)
        title = path == nil
            ? L10n.string("mobile.iroh.private.custom.add", defaultValue: "Add Private Addresses")
            : L10n.string("mobile.iroh.private.custom.edit", defaultValue: "Edit Private Addresses")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("mobile.common.save", defaultValue: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() }
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : 2 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? L10n.string("mobile.iroh.private.custom.addresses", defaultValue: "Numeric IP Addresses") : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        return L10n.string("mobile.iroh.private.custom.addresses.footer", defaultValue: "Enter one IPv4 or IPv6 address per line, without a port. cmux combines it with the Mac's current broker-authenticated Iroh UDP port.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = L10n.string("mobile.iroh.private.custom.mac", defaultValue: "Mac")
            cell.detailTextLabel?.text = selectedMacDisplayName
            cell.accessoryType = existing == nil ? .disclosureIndicator : .none
            cell.selectionStyle = existing == nil ? .default : .none
            return cell
        }
        if indexPath.row == 1 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = L10n.string("mobile.iroh.private.custom.enabled", defaultValue: "Use These Addresses")
            let control = UISwitch()
            control.isOn = isEnabled
            control.addAction(UIAction { [weak self] action in
                guard let control = action.sender as? UISwitch else { return }
                self?.isEnabled = control.isOn
            }, for: .valueChanged)
            cell.accessoryView = control
            cell.selectionStyle = .none
            return cell
        }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let editor = UITextView()
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.keyboardType = .numbersAndPunctuation
        editor.text = addressesText
        editor.delegate = self
        editor.accessibilityIdentifier = "MobileIrohCustomPrivateAddresses"
        cell.contentView.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            editor.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            editor.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard existing == nil, indexPath.section == 0 else { return }
        let alert = UIAlertController(title: L10n.string("mobile.iroh.private.custom.mac", defaultValue: "Mac"), message: nil, preferredStyle: .actionSheet)
        for mac in availableMacs {
            alert.addAction(UIAlertAction(title: displayName(mac.displayName), style: .default) { [weak self] _ in
                self?.selectedMacDeviceID = mac.id
                self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        alert.popoverPresentationController?.sourceRect = tableView.cellForRow(at: indexPath)?.bounds ?? .zero
        present(alert, animated: true)
    }

    func textViewDidChange(_ textView: UITextView) { addressesText = textView.text }

    private var selectedMacDisplayName: String {
        let name = availableMacs.first(where: { $0.id == selectedMacDeviceID })?.displayName
            ?? existing?.macDisplayName
            ?? ""
        return displayName(name)
    }

    private func displayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("mobile.iroh.private.custom.unnamedMac", defaultValue: "Mac") : trimmed
    }

    private struct Validation {
        let addresses: [String]
        let canSave: Bool
    }

    private var validation: Validation {
        let addresses = addressesText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Validation(
            addresses: addresses,
            canSave: !selectedMacDeviceID.isEmpty
                && !addresses.isEmpty
                && addresses.count <= CmxIrohCustomPrivatePathDraft.maximumAddressCount
                && addresses.allSatisfy { (try? CmxIrohCustomPrivateAddress($0)) != nil }
        )
    }

    private func save() {
        guard !isSaving else { return }
        let validation = validation
        guard validation.canSave else {
            let alert = UIAlertController(
                title: L10n.string("mobile.iroh.saveFailed", defaultValue: "Could Not Save Networking Settings"),
                message: L10n.string("mobile.iroh.private.custom.validation", defaultValue: "Choose a Mac and enter up to eight valid numeric IPv4 or IPv6 addresses, one per line."),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.string("mobile.common.ok", defaultValue: "OK"), style: .default))
            present(alert, animated: true)
            return
        }
        isSaving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let draft = CmxIrohCustomPrivatePathDraft(
            macDeviceID: selectedMacDeviceID,
            macDisplayName: selectedMacDisplayName,
            addresses: validation.addresses,
            isEnabled: isEnabled
        )
        Task { [weak self] in
            guard let self else { return }
            if await onSave(draft) { dismiss(animated: true) }
            isSaving = false
            navigationItem.rightBarButtonItem?.isEnabled = true
        }
    }
}
#endif
