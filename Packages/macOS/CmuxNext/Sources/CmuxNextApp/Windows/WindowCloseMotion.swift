import AppKit
import CmuxNextDesign

/// A window the person closes fades out as a whole before it closes. Red: closes at once.
@MainActor final class WindowCloseMotion {
    let window: NSWindow
    private let close: () -> Void
    private var finished = false

    static func fades(_ window: NSWindow, animates: Bool = Motion.animatesMovement) -> Bool { true }

    init(window: NSWindow, parameters: SpringParameters = Motion.spring(.exit), close: @escaping () -> Void) {
        self.window = window
        self.close = close
    }

    func start(handingKeysTo next: NSWindow?, driven: Bool = true) { finish() }

    @discardableResult
    func step(_ dt: Double) -> Bool { false }

    func finish() {
        guard !finished else { return }
        finished = true
        close()
    }
}
