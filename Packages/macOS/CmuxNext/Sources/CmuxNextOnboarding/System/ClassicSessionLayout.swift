import Foundation

/// A terminal tab copied from a classic cmux session.
public struct ClassicSessionTab: Codable, Equatable, Sendable {
    public let workingDirectory: String?
    public let title: String?

    public init(workingDirectory: String?, title: String?) {
        self.workingDirectory = workingDirectory
        self.title = title
    }
}

/// A pane and its tabs, in the order shown by classic cmux.
public struct ClassicSessionPane: Codable, Equatable, Sendable {
    public let tabs: [ClassicSessionTab]
    public let selectedTab: Int

    public init(tabs: [ClassicSessionTab], selectedTab: Int = 0) {
        self.tabs = tabs
        self.selectedTab = selectedTab
    }
}

/// The classic split tree. A pane is a leaf; a split preserves its axis and divider.
public indirect enum ClassicSessionLayout: Codable, Equatable, Sendable {
    case pane(ClassicSessionPane)
    case split(orientation: Orientation, ratio: Double, first: ClassicSessionLayout, second: ClassicSessionLayout)

    public enum Orientation: String, Codable, Sendable { case horizontal, vertical }
}

