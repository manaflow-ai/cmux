import CoreGraphics

/// Where an agent's visual-evidence launch puts the app's windows, so a
/// screenshot needs no window moves and no focus change.
///
/// Read only with `CMUX_NEXT_NO_ACTIVATE=1`:
///
/// - `CMUX_NEXT_TEST_WINDOW_SCREEN=<index|last>`: the `NSScreen.screens`
///   index (0 is the menu-bar screen). `last` is the agent default: the last
///   screen, which is a secondary display whenever more than one exists. An
///   index past the end also means the last screen.
/// - `CMUX_NEXT_TEST_WINDOW_FRAME=x,y,w,h` (optional, points): the frame
///   inside that screen's visible frame, `x,y` from its top-left corner.
///   Without it the window is 1100x720, centered. The frame is clamped to
///   the visible frame.
///
/// Placed windows are ordered front with `orderFrontRegardless`; the app is
/// never activated and no window becomes key. Each further window cascades
/// by ``cascadeStep`` so every one stays visible.
struct TestWindowPlacement: Sendable, Equatable {
    enum Screen: Sendable, Equatable {
        case index(Int)
        case last
    }

    static let screenKey = "CMUX_NEXT_TEST_WINDOW_SCREEN"
    static let frameKey = "CMUX_NEXT_TEST_WINDOW_FRAME"
    static let defaultSize = CGSize(width: 1100, height: 720)
    static let cascadeStep: CGFloat = 24

    var screen: Screen
    /// Top-left-origin frame inside the screen's visible frame.
    var frame: CGRect?

    /// Nil unless no-activate is on and at least one knob is set. A malformed
    /// value disables the knob it belongs to rather than guessing.
    static func parse(_ environment: [String: String], noActivate: Bool) -> TestWindowPlacement? {
        guard noActivate else { return nil }
        let screenValue = environment[screenKey]?.trimmingCharacters(in: .whitespaces) ?? ""
        let frame = environment[frameKey].flatMap(parseFrame)
        let screen: Screen?
        switch screenValue.lowercased() {
        case "": screen = frame == nil ? nil : .index(0)
        case "last": screen = .last
        default: screen = Int(screenValue).flatMap { $0 >= 0 ? .index($0) : nil }
        }
        guard let screen else { return nil }
        return TestWindowPlacement(screen: screen, frame: frame)
    }

    /// `x,y,w,h` with a positive size.
    static func parseFrame(_ value: String) -> CGRect? {
        let parts = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
              w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The AppKit (bottom-left origin) frame for the `ordinal`-th placed
    /// window, given each screen's visible frame in `NSScreen.screens` order.
    func windowFrame(ordinal: Int, visibleFrames: [CGRect]) -> CGRect? {
        guard !visibleFrames.isEmpty else { return nil }
        let visible: CGRect
        switch screen {
        case .last: visible = visibleFrames[visibleFrames.count - 1]
        case .index(let index): visible = visibleFrames[min(index, visibleFrames.count - 1)]
        }
        let width = min(frame?.width ?? Self.defaultSize.width, visible.width)
        let height = min(frame?.height ?? Self.defaultSize.height, visible.height)
        let offset = Self.cascadeStep * CGFloat(max(ordinal, 0))
        var left = frame.map { $0.minX } ?? (visible.width - width) / 2
        var top = frame.map { $0.minY } ?? (visible.height - height) / 2
        left = min(max(left + offset, 0), visible.width - width)
        top = min(max(top + offset, 0), visible.height - height)
        return CGRect(x: visible.minX + left, y: visible.maxY - top - height, width: width, height: height)
    }
}
