import AppKit
import CmuxNextHomeEngine

/// The Chief tab's one-tap switch (Lawrence 2026-10-19): "Chief" (the Hosted
/// Chief, the default) or "Chief (Mac mini)" (the Chief placed on a paired
/// server). Shown only on a cloud Chief's conversation while both exist.
@MainActor
final class HomeChiefSwitch: NSSegmentedControl {
    private weak var service: HomeService?
    private var watch: Task<Void, Never>?

    init(service: HomeService, conversation: String) {
        self.service = service
        super.init(frame: .zero)
        segmentCount = 2
        trackingMode = .selectOne
        controlSize = .small
        segmentStyle = .rounded
        setLabel(HomeStrings.chiefName, forSegment: 0)
        setLabel(CloudChiefs.placedName, forSegment: 1)
        toolTip = Self.help
        setAccessibilityLabel(Self.help)
        target = self
        action = #selector(picked)
        isHidden = true
        // task-owner: lives as long as this control; event-driven (Observation)
        watch = Task { [weak self] in
            for await (chiefs, shown) in ObservationStream({ (service.cloudChiefs, service.cloudChief?.mainConversation) }) {
                guard let self else { return }
                isHidden = !(chiefs.canSwitch && chiefs.chief(for: conversation) != nil)
                selectedSegment = shown != nil && shown == chiefs.placed?.mainConversation ? 1 : 0
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { watch?.cancel() }
    }

    @objc private func picked() {
        service?.switchChief(to: selectedSegment == 1 ? .placed : .hosted)
    }

    static var help: String {
        String(localized: "home.chief.switch.help", defaultValue: "Choose which Chief answers here", table: "Cloud", bundle: .module)
    }
}
