/// `sidebar.workspaceRow` resolved values (SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE);
/// the elements and kinds are in WorkspaceRowElement.swift.
/// One resolved set: which elements show and the second line's order.
public nonisolated struct WorkspaceRowElements: Hashable, Sendable {
    public var shown: Set<WorkspaceRowElement>
    /// Every second-line element once, in display order.
    public var secondLineOrder: [WorkspaceRowElement]

    public init(shown: Set<WorkspaceRowElement>, secondLineOrder: [WorkspaceRowElement] = WorkspaceRowElement.secondLine) {
        self.shown = shown
        self.secondLineOrder = Self.completeOrder(secondLineOrder)
    }

    /// Name, user icon and unread/attention mark only. `working` is on so the
    /// agent-working indicator shows (WORKING-AND-LOADING-INDICATORS).
    public static let minimal = Self(shown: [.icon, .working])

    /// The default set: `minimal` plus progress (the busy glyph and bar of
    /// work that is not an agent turn). What agents and scripts report as
    /// words (status entries, the log line) is opt-in since Lawrence
    /// 2026-10-21 ("sidebar must be kept minimal by default"): a row is its
    /// name and one state mark; the hover card says the rest. An unread
    /// notification's text is opt-in too (`notification`, classic's second line).
    public static let standard = Self(shown: minimal.shown.union([.progress]))

    public func shows(_ element: WorkspaceRowElement) -> Bool { shown.contains(element) }

    /// The shown second-line elements in order.
    public var secondLine: [WorkspaceRowElement] { secondLineOrder.filter(shown.contains) }

    /// `order`'s second-line elements (first occurrence wins), then the ones
    /// it left out, in the default order.
    public static func completeOrder(_ order: [WorkspaceRowElement]) -> [WorkspaceRowElement] {
        var seen = Set<WorkspaceRowElement>()
        let listed = order.filter { $0.isSecondLine && seen.insert($0).inserted }
        return listed + WorkspaceRowElement.secondLine.filter { !seen.contains($0) }
    }
}

/// A kind's changes to the base set; an absent element keeps the base value.
public nonisolated struct WorkspaceRowOverride: Hashable, Sendable {
    public var elements: [WorkspaceRowElement: Bool]
    public var secondLineOrder: [WorkspaceRowElement]?

    public init(elements: [WorkspaceRowElement: Bool] = [:], secondLineOrder: [WorkspaceRowElement]? = nil) {
        self.elements = elements
        self.secondLineOrder = secondLineOrder
    }

    public var isEmpty: Bool { elements.isEmpty && secondLineOrder == nil }
}

/// `sidebar.workspaceRow`: the base set plus per-kind overrides.
public nonisolated struct WorkspaceRowPreferences: Hashable, Sendable {
    public var base: WorkspaceRowElements
    public var overrides: [WorkspaceRowKind: WorkspaceRowOverride]

    public init(base: WorkspaceRowElements = .standard, overrides: [WorkspaceRowKind: WorkspaceRowOverride] = [:]) {
        self.base = base
        self.overrides = overrides
    }

    public static let defaults = Self()

    /// What a row of `kind` shows: the base set with that kind's overrides.
    public func resolved(for kind: WorkspaceRowKind) -> WorkspaceRowElements {
        guard let change = overrides[kind], !change.isEmpty else { return base }
        var shown = base.shown
        for (element, on) in change.elements {
            if on { shown.insert(element) } else { shown.remove(element) }
        }
        return WorkspaceRowElements(shown: shown, secondLineOrder: change.secondLineOrder ?? base.secondLineOrder)
    }

    /// Whether a row of some kind shows `element`, with that kind's override.
    public func showsAnywhere(_ element: WorkspaceRowElement) -> Bool {
        WorkspaceRowKind.allCases.contains { resolved(for: $0).shows(element) }
    }
}
