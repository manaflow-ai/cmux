/// Cold-path configuration used to recreate a Ghostty surface in a workspace
/// worker. Hot keyboard, mouse, resize, and frame messages do not use Codable.
public struct RendererSurfaceConfiguration: Codable, Equatable, Sendable {
    public let identity: RendererSurfaceIdentity
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let scaleX: Double
    public let scaleY: Double
    public let fontSize: Float
    public let workingDirectory: String?
    public let command: String?
    public let initialInput: String?
    public let environment: [String: String]
    public let waitAfterCommand: Bool
    public let context: UInt32
    public let manualIO: Bool

    public init(
        identity: RendererSurfaceIdentity,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        scaleX: Double,
        scaleY: Double,
        fontSize: Float,
        workingDirectory: String?,
        command: String?,
        initialInput: String?,
        environment: [String: String],
        waitAfterCommand: Bool,
        context: UInt32,
        manualIO: Bool
    ) {
        self.identity = identity
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory
        self.command = command
        self.initialInput = initialInput
        self.environment = environment
        self.waitAfterCommand = waitAfterCommand
        self.context = context
        self.manualIO = manualIO
    }
}
