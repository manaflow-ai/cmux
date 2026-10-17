import CmuxNextCompat

/// Keeps Debug Settings observations out of the app target's size-capped page settings.
@MainActor
public final class AgentPaneDebugSettings {
    public private(set) var sidebarPreviewVariant = AgentPaneSidebarPreviewVariant.card
    private var reasoningSliderObservation: Task<Void, Never>?
    private var sidebarPreviewVariantObservation: Task<Void, Never>?

    public init() {}

    /// Follows the opt-in composer slider and sidebar preview controls.
    public func follow(
        setComposer: @escaping @MainActor (Bool, String) -> Void,
        push: @escaping @MainActor () -> Void
    ) {
        reasoningSliderObservation?.cancel()
        sidebarPreviewVariantObservation?.cancel()
        reasoningSliderObservation = Task { [weak self] in
            for await on in ObservationStream({ (AgentPaneTunables.reasoningSlider.value, AgentPaneTunables.reasoningSliderStyle.value) }) {
                guard self != nil else { return }
                setComposer(on.0, on.1.rawValue)
                push()
            }
        }
        sidebarPreviewVariantObservation = Task { [weak self] in
            for await on in ObservationStream({ AgentPaneTunables.sidebarPreviewVariant.value }) {
                guard let self else { return }
                sidebarPreviewVariant = on
                push()
            }
        }
    }

    /// Pushes the current sidebar preview choice to a newly loaded page.
    public func apply(to view: AgentPaneView) {
        sidebarPreviewVariant.push(to: view)
    }
}
