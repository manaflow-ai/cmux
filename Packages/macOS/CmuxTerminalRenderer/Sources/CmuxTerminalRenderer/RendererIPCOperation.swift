/// Stable operation numbers used on the renderer worker's XPC hot path.
///
/// Values are append-only because independently launched workers can briefly
/// overlap an app update while an existing workspace is being restored.
public enum RendererIPCOperation: UInt64, Sendable {
    case hello = 1
    case ready = 2
    case createSurface = 3
    case surfaceCreated = 4
    case destroySurface = 5
    case resize = 6
    case focus = 7
    case occlusion = 8
    case key = 9
    case text = 10
    case markedText = 11
    case unmarkText = 12
    case mousePosition = 13
    case mouseButton = 14
    case mouseScroll = 15
    case mousePressure = 16
    case processOutput = 17
    case processInput = 18
    case frame = 19
    case action = 20
    case clipboardRead = 21
    case clipboardReadResponse = 22
    case clipboardWrite = 23
    case search = 24
    case snapshot = 25
    case renderNow = 26
    case updateConfiguration = 27
    case processExited = 28
    case failure = 29
    case shutdown = 30
    case ping = 31
    case pong = 32
    case registerEndpoint = 33
    case requestEndpoint = 34
    case endpoint = 35
}
