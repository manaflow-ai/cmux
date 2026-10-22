/// The result of one ``PhoneSetupCheck``: the next step and what it found.
public struct PhoneSetupStatus: Sendable, Hashable {
    /// The first step that is not done (``PhoneSetupStep/ready`` when none).
    public var step: PhoneSetupStep
    /// The Xcode app in use (`/Applications/Xcode.app`), when one is installed.
    public var xcodeApp: String?
    /// True when only the command line tools are installed (the setup screen says why they are not enough).
    public var hasOnlyCommandLineTools: Bool
    /// The newest available iOS runtime, when one is installed.
    public var runtime: SimctlRuntime?

    public init(step: PhoneSetupStep, xcodeApp: String? = nil, hasOnlyCommandLineTools: Bool = false, runtime: SimctlRuntime? = nil) {
        self.step = step
        self.xcodeApp = xcodeApp
        self.hasOnlyCommandLineTools = hasOnlyCommandLineTools
        self.runtime = runtime
    }
}
