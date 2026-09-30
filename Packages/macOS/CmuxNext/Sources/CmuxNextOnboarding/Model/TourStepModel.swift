import Foundation
public import Observation

/// One page of the key ideas tour.
public nonisolated struct TourPage: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case palette, keyTiers, rooms, splits, screens
    }

    public var kind: Kind
    /// Actions whose live shortcuts the page shows.
    public var actionIDs: [String]
    public var symbol: String

    public var id: String { kind.rawValue }
}

/// Key ideas tour: short pages, each skippable; the step's Continue ends it.
@MainActor
@Observable
public final class TourStepModel {
    public static let pages: [TourPage] = [
        TourPage(kind: .palette, actionIDs: ["commandPalette"], symbol: "command"),
        TourPage(kind: .keyTiers, actionIDs: ["focusLeft", "focusRight"], symbol: "keyboard"),
        TourPage(kind: .rooms, actionIDs: ["room.next", "room.previous"], symbol: "circle.grid.2x1"),
        TourPage(kind: .splits, actionIDs: ["splitRight", "splitDown"], symbol: "rectangle.split.2x1"),
        TourPage(kind: .screens, actionIDs: ["screen.toggleSwitcher", "screen.new"], symbol: "rectangle.stack"),
    ]

    public private(set) var page = 0
    @ObservationIgnored private let services: any OnboardingServices

    init(services: any OnboardingServices) {
        self.services = services
    }

    public var current: TourPage { Self.pages[page] }

    public func show(_ index: Int) {
        page = min(max(index, 0), Self.pages.count - 1)
    }

    public func shortcuts(for page: TourPage) -> [String] {
        page.actionIDs.compactMap { services.shortcutDisplay(for: $0) }
    }
}
