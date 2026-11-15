import AppKit

/// What one card view keeps between its draws (SwiftUI's `@State` in the card before): an open
/// Details or tool list, Review taken, the typed key. A change asks the card to draw again.
///
/// It also holds the targets and delegates the drawn controls use (AppKit keeps them weakly), until
/// the next draw replaces them.
@MainActor
final class McpConnectCardState {
    /// Details is open (the compact row).
    var open = false { didSet { if open != oldValue { changed() } } }
    /// Review was taken (the two-step card).
    var reviewing = false { didSet { if reviewing != oldValue { changed() } } }
    /// The connected tool list is open.
    var toolsOpen = false { didSet { if toolsOpen != oldValue { changed() } } }
    /// The key typed in the private field. It never leaves the card but through ``McpConnectCardActions/submitKey``.
    var key = ""
    /// Draws the card again.
    var changed: @MainActor () -> Void = {}
    private var held: [AnyObject] = []

    /// Keeps `object` alive until ``releaseHeld()``; returns it.
    @discardableResult
    func hold<T: AnyObject>(_ object: T) -> T {
        held.append(object)
        return object
    }

    /// Lets go of the last draw's targets and delegates.
    func releaseHeld() { held.removeAll() }
}
