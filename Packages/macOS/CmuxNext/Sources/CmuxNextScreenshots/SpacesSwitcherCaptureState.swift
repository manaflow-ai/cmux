#if DEBUG || CMUX_BENCH_HOOKS
/// A capture fixture that remains live while the driver takes its stills.
@MainActor
public final class SpacesSwitcherCaptureState {
    public let profileID: String
    public let workspaceID: String
    public let windowID: String
    private var teardown: (@MainActor () async -> [String])?

    public init(profileID: String, workspaceID: String, windowID: String,
                teardown: @escaping @MainActor () async -> [String]) {
        self.profileID = profileID
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.teardown = teardown
    }

    public func end() async -> [String] {
        guard let teardown else { return [] }
        let errors = await teardown()
        if errors.isEmpty { self.teardown = nil }
        return errors
    }
}
#endif
