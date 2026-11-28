/// Routes toolbar actions back to the currently registered inline preview.
@MainActor
public final class ChatArtifactInlineActionHost {
    private var registrationID = 0
    private var descriptorID: String?
    private var actions: Set<ChatArtifactAction> = []
    private var performer: ((ChatArtifactAction) -> Void)?

    /// Creates an empty action host.
    public init() {}

    /// Performs an action only when the toolbar descriptor still matches the preview.
    /// - Parameters:
    ///   - action: Action selected in the host toolbar.
    ///   - descriptorID: Identity of the descriptor used to render the toolbar button.
    public func perform(_ action: ChatArtifactAction, descriptorID: String) {
        guard self.descriptorID == descriptorID, actions.contains(action) else { return }
        performer?(action)
    }

    func register(
        descriptor: ChatArtifactInlineActionDescriptor,
        performer: @escaping @MainActor (ChatArtifactAction) -> Void
    ) -> Int {
        registrationID += 1
        descriptorID = descriptor.id
        actions = Set(descriptor.actions)
        self.performer = performer
        return registrationID
    }

    func clear(registrationID: Int) {
        guard self.registrationID == registrationID else { return }
        descriptorID = nil
        actions = []
        performer = nil
    }
}
