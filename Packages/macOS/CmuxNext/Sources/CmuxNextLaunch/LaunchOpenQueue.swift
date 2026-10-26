public import Foundation

/// What macOS hands the app between `applicationDidFinishLaunching` and the moment its services
/// exist (the settings launch read still in flight on a cold disk, p08-startup 025): opened URLs
/// and Handoff activities, kept in arrival order and handed over once, when the launch builds the
/// services. Chrome keeps a launch's URLs the same way until the app is fully initialized
/// (AppController's `_startupUrls`, chrome/browser/app_controller_mac.mm).
///
/// ```swift
/// guard let services else { return launchOpens.hold(.url(url)) }   // before the services
/// launchOpens.release { open($0) }                                // once they exist
/// ```
@MainActor
public final class LaunchOpenQueue {
    /// One hand-over from macOS.
    public enum Item: Equatable, Sendable {
        /// A URL from `kAEGetURL` or `application(_:open:)`.
        case url(URL)
        /// A Handoff activity (`application(_:continue:restorationHandler:)`).
        case activity(type: String, webpageURL: URL?)
    }

    private var held: [Item] = []

    public init() {}

    /// The items kept and not handed over yet, in arrival order.
    public var items: [Item] { held }

    /// Keeps `item` until ``release(_:)``.
    public func hold(_ item: Item) {
        held.append(item)
    }

    /// Hands every kept item to `deliver`, in arrival order, and keeps none after.
    public func release(_ deliver: (Item) -> Void) {
        let items = held
        held = []
        items.forEach(deliver)
    }
}
