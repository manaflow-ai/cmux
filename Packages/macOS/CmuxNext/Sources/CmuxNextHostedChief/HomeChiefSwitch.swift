import AppKit
import CmuxNextCompat
import CmuxNextHomeEngine

/// The Chief tab's one-tap switch (Lawrence 2026-10-19): "Chief" (the Hosted
/// Chief, the default) or "Chief (Mac mini)" (the Chief placed on a paired
/// server). Shown only on a cloud Chief's conversation while both exist.
/// `state` reads the Chief tab's cloud Chiefs and the shown main conversation (observed); `pick` switches.
@MainActor
public final class HomeChiefSwitch: NSSegmentedControl {
    private let pick: @MainActor (HomeChiefChoice) -> Void
    private var watch: Task<Void, Never>?

    public init(conversation: String, state: @escaping @MainActor @Sendable () -> (chiefs: HomeCloudChiefs, shown: String?),
                pick: @escaping @MainActor (HomeChiefChoice) -> Void) {
        self.pick = pick
        super.init(frame: .zero)
        segmentCount = 2
        trackingMode = .selectOne
        controlSize = .small
        segmentStyle = .rounded
        setLabel(HomeStrings.chiefName, forSegment: 0)
        setLabel(HomeCloudChiefs.placedName, forSegment: 1)
        toolTip = Self.help
        setAccessibilityLabel(Self.help)
        target = self
        action = #selector(picked)
        isHidden = true
        // task-owner: lives as long as this control; event-driven (Observation)
        watch = Task { [weak self] in
            for await (chiefs, shown) in ObservationStream(state) {
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

    /// Centered under the transcript's header (avatar and name), so it never covers the name in a narrow
    /// dock; `column` is the transcript's frame in a view that is not flipped.
    public func place(column: NSRect, header: CGFloat) {
        let size = fittingSize
        frame = NSRect(x: max(0, column.midX - size.width / 2), y: column.maxY - header - size.height - 6, width: size.width, height: size.height)
    }

    @objc private func picked() {
        pick(selectedSegment == 1 ? .placed : .hosted)
    }

    static var help: String { HomeCloudChiefs.switchHelp }
}
