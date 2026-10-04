public import Foundation

/// Opens the tab for a window a page opens from a driven tab.
///
/// Models the app as it is: the tab is created with its URL, which it
/// starts loading at once, and handed to the sessions afterwards.
@MainActor
public struct BrowserReplPopupOpening<Tab> {
    private let create: (URL?) -> Tab?
    private let handOver: (Tab) -> Void
    private let load: (Tab, URL) -> Void

    public init(create: @escaping (URL?) -> Tab?, handOver: @escaping (Tab) -> Void, load: @escaping (Tab, URL) -> Void) {
        self.create = create
        self.handOver = handOver
        self.load = load
    }

    public func open(_ url: URL, handOverFirst: Bool) -> Tab? {
        guard let tab = create(url) else { return nil }
        handOver(tab)
        return tab
    }
}
