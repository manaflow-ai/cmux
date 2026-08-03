import Observation

/// Routes toolbar actions back to the currently registered inline preview.
@MainActor
@Observable
public final class ChatArtifactInlineActionHost {
    /// Toolbar state for the currently registered preview.
    public private(set) var descriptor: ChatArtifactInlineActionDescriptor?

    @ObservationIgnored
    private var registrationID = 0
    @ObservationIgnored
    private var performer: ((ChatArtifactAction) -> Void)?

    /// Creates an empty action host.
    public init() {}

    /// Performs an action only when the toolbar descriptor still matches the preview.
    /// - Parameters:
    ///   - action: Action selected in the host toolbar.
    ///   - descriptorID: Identity of the descriptor used to render the toolbar button.
    public func perform(_ action: ChatArtifactAction, descriptorID: String) {
        guard descriptor?.id == descriptorID,
              descriptor?.actions.contains(action) == true else { return }
        performer?(action)
    }

    func register(
        descriptor: ChatArtifactInlineActionDescriptor,
        performer: @escaping @MainActor (ChatArtifactAction) -> Void
    ) -> Int {
        registrationID += 1
        self.descriptor = descriptor
        self.performer = performer
        return registrationID
    }

    func clear(registrationID: Int) {
        guard self.registrationID == registrationID else { return }
        descriptor = nil
        performer = nil
    }
}
