import AppKit
import CmuxSimulator

@MainActor
class SimulatorNotificationPrivacyToolsContent: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let bundleIdentifier = SimulatorClosureTextField()
    private let servicePicker = SimulatorClosurePopUpButton()
    private let grantButton = SimulatorClosureButton(title: String(localized: simulatorStrings.grant))
    private let revokeButton = SimulatorClosureButton(title: String(localized: simulatorStrings.revoke))
    private let resetButton = SimulatorClosureButton(title: String(localized: simulatorStrings.reset))
    private let snapshotStack = NSStackView()
    private let services = SimulatorPrivacyService.allCases
    private var lastHydratedDeviceID: String?
    private var snapshotSignature = ""

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.notificationsAndPrivacy)
        bundleIdentifier.placeholderString = String(localized: simulatorStrings.bundleIdentifier)
        bundleIdentifier.onChange = { [weak self] _ in self?.updateButtonState() }
        add(bundleIdentifier)
        let push = SimulatorClosureButton(title: String(localized: simulatorStrings.sendPush)) {
            [weak self] in
            guard let self else { return }
            let bundle = bundleIdentifier.stringValue
            coordinator.scheduleControlAction("push-notification") {
                await $0.pushNotification(bundleIdentifier: bundle)
            }
        }
        push.identifier = NSUserInterfaceItemIdentifier("push")
        add(push)
        servicePicker.addItems(withTitles: services.map { String(localized: simulatorStrings.privacy($0)) })
        servicePicker.handler = { [weak self] _ in self?.updateButtonState() }
        add(servicePicker)
        grantButton.handler = { [weak self] in self?.apply(.grant) }
        revokeButton.handler = { [weak self] in self?.apply(.revoke) }
        resetButton.handler = { [weak self] in self?.apply(.reset) }
        let read = SimulatorClosureButton(title: String(localized: simulatorStrings.readPermissions)) {
            [weak self] in
            guard let self else { return }
            let bundle = bundleIdentifier.stringValue
            coordinator.scheduleControlAction("read-privacy") {
                await $0.readPrivacy(bundleIdentifier: bundle)
            }
        }
        add(simulatorRow([grantButton, revokeButton, resetButton, read]))
        snapshotStack.orientation = .vertical
        snapshotStack.alignment = .leading
        snapshotStack.spacing = 4
        add(snapshotStack)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        if lastHydratedDeviceID != coordinator.selectedDeviceID {
            lastHydratedDeviceID = coordinator.selectedDeviceID
            Task { @MainActor [weak coordinator] in
                guard let coordinator, coordinator.supports(.foregroundApplication) else { return }
                await coordinator.refreshForegroundApplication()
            }
        }
        let adopted = simulatorPrivacyBundleIdentifier(
            current: bundleIdentifier.stringValue,
            foreground: coordinator.foregroundApplication?.bundleIdentifier
        )
        if adopted != bundleIdentifier.stringValue { bundleIdentifier.stringValue = adopted }
        updateButtonState()
        updateSnapshot()
    }

    private func updateButtonState() {
        let service = selectedService
        let bundle = bundleIdentifier.stringValue
        grantButton.isEnabled = simulatorPrivacyActionIsEnabled(.grant, service: service, bundleIdentifier: bundle)
        revokeButton.isEnabled = simulatorPrivacyActionIsEnabled(.revoke, service: service, bundleIdentifier: bundle)
        resetButton.isEnabled = simulatorPrivacyActionIsEnabled(.reset, service: service, bundleIdentifier: bundle)
        contentStack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "push" })?.isHidden = false
        (contentStack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "push" }) as? NSButton)?.isEnabled = !bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateSnapshot() {
        let values = coordinator.privacySnapshot?.authorizations ?? [:]
        let nextSignature = values.keys.sorted { $0.rawValue < $1.rawValue }.map {
            "\($0.rawValue):\(String(describing: values[$0]))"
        }.joined(separator: "|")
        guard nextSignature != snapshotSignature else { return }
        snapshotSignature = nextSignature
        snapshotStack.arrangedSubviews.forEach { snapshotStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for service in values.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let authorization = values[service] else { continue }
            snapshotStack.addArrangedSubview(simulatorValueRow(
                simulatorStrings.privacy(service),
                value: String(localized: simulatorStrings.authorization(authorization))
            ))
        }
    }

    private var selectedService: SimulatorPrivacyService {
        guard services.indices.contains(servicePicker.indexOfSelectedItem) else { return .all }
        return services[servicePicker.indexOfSelectedItem]
    }

    private func apply(_ action: SimulatorPrivacyAction) {
        let bundle = bundleIdentifier.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = selectedService
        guard simulatorPrivacyActionIsEnabled(action, service: service, bundleIdentifier: bundle) else { return }
        coordinator.scheduleControlAction("set-privacy") {
            await $0.setPrivacy(action, service: service, bundleIdentifier: bundle)
        }
    }
}

func simulatorPrivacyActionIsEnabled(
    _ action: SimulatorPrivacyAction,
    service: SimulatorPrivacyService,
    bundleIdentifier: String
) -> Bool {
    guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
    }
    return switch action {
    case .grant, .revoke:
        service != .all
    case .reset:
        true
    }
}

func simulatorPrivacyBundleIdentifier(current: String, foreground: String?) -> String {
    guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let foreground = foreground?.trimmingCharacters(in: .whitespacesAndNewlines),
          !foreground.isEmpty else { return current }
    return foreground
}
