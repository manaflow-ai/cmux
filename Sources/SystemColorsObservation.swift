/// Main-actor observation token for AppKit system-color changes.
@MainActor
protocol SystemColorsObservation: AnyObject {
    func invalidate()
}
