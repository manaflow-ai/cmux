public import CmuxNextControl

/// Resolves a health part's id to where it is on screen (``AppHealthPlace``): the App's answer for the page parts
/// (`page:<n>`, `renderer:<n>`), nil for the parts that have no place (the session service, the page server).
@MainActor
public struct AppHealthPlaces {
    private let place: @MainActor (String) -> AppHealthPlace?

    /// - Parameter place: The place of a part id, nil when it has none (tests pass a fixed table).
    public init(_ place: @escaping @MainActor (String) -> AppHealthPlace?) {
        self.place = place
    }

    /// No part has a place (the parts keep their model labels).
    public static var none: AppHealthPlaces { AppHealthPlaces { _ in nil } }

    /// The place of part `id`, nil when it has none.
    public func callAsFunction(_ id: String) -> AppHealthPlace? { place(id) }

    /// `headline` as the footer line says it: a page part named by its chat.
    public func headline(_ headline: AppHealth.Headline?) -> AppHealth.Headline? {
        headline
    }
}
