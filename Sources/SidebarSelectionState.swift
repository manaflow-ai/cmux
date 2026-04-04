import SwiftUI

@MainActor
final class SidebarSelectionState: ObservableObject {
    @Published var selection: SidebarSelection

    init(selection: SidebarSelection = .tabs) {
        self.selection = selection
    }
}

let sidebarInteractionCoordinateSpace = "cmux.sidebarInteraction"

enum SidebarHitTarget: Hashable {
    case emptyArea
    case groupHeader(groupId: UUID)
    case workspace(workspaceId: UUID, parentGroupId: UUID?)
}

struct SidebarPendingClick: Equatable {
    let target: SidebarHitTarget
    let location: CGPoint?
    let timestamp: TimeInterval
    let selectedGroupIdContext: UUID?
}

struct SidebarDragSession: Equatable {
    enum Payload: Equatable {
        case workspace(UUID)
        case workspaces([UUID])
        case group(UUID)
    }

    let payload: Payload
    let startTarget: SidebarHitTarget
    let startLocation: CGPoint
    var currentLocation: CGPoint
}

enum SidebarInsertionTarget: Equatable {
    case topLevel(index: Int)
    case groupHeader(groupId: UUID)
    case withinGroup(groupId: UUID, index: Int)
}

struct SidebarRowLayoutEntry: Equatable {
    let target: SidebarHitTarget
    let frame: CGRect
}

struct SidebarClickResult: Equatable {
    let isDoubleClick: Bool
    let selectedGroupIdContext: UUID?
}

struct SidebarRowLayoutPreferenceKey: PreferenceKey {
    static var defaultValue: [SidebarRowLayoutEntry] = []

    static func reduce(value: inout [SidebarRowLayoutEntry], nextValue: () -> [SidebarRowLayoutEntry]) {
        value.append(contentsOf: nextValue())
    }
}

private struct SidebarRowLayoutReporter: ViewModifier {
    let target: SidebarHitTarget

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarRowLayoutPreferenceKey.self,
                    value: [
                        SidebarRowLayoutEntry(
                            target: target,
                            frame: proxy.frame(in: .named(sidebarInteractionCoordinateSpace))
                        )
                    ]
                )
            }
        )
    }
}

extension View {
    func reportSidebarLayout(target: SidebarHitTarget) -> some View {
        modifier(SidebarRowLayoutReporter(target: target))
    }
}

@MainActor
final class SidebarInteractionController: ObservableObject {
    static let dragThreshold: CGFloat = 5
    static var doubleClickInterval: TimeInterval {
        NSEvent.doubleClickInterval
    }

    @Published var hoverTarget: SidebarHitTarget?
    @Published var dragSession: SidebarDragSession?
    @Published var insertionTarget: SidebarInsertionTarget?
    @Published private(set) var rowLayoutEntries: [SidebarRowLayoutEntry] = []

    func updateRowLayoutEntries(_ entries: [SidebarRowLayoutEntry]) {
        var seen = Set<SidebarHitTarget>()
        let deduped = entries.filter { seen.insert($0.target).inserted }
        guard rowLayoutEntries != deduped else { return }
        rowLayoutEntries = deduped
    }

    func frame(for target: SidebarHitTarget) -> CGRect? {
        rowLayoutEntries.first(where: { $0.target == target })?.frame
    }

    func hitTarget(at location: CGPoint) -> SidebarHitTarget? {
        if let directHit = rowLayoutEntries.first(where: {
            $0.target != .emptyArea && $0.frame.contains(location)
        }) {
            return directHit.target
        }
        return rowLayoutEntries.first(where: {
            $0.target == .emptyArea && $0.frame.contains(location)
        })?.target
    }

    func clearInteractionState() {
        hoverTarget = nil
        dragSession = nil
        insertionTarget = nil
        pendingClick = nil
    }

    func cancelPendingClick() {
        pendingClick = nil
    }

    private var pendingClick: SidebarPendingClick?

    func registerClick(
        on target: SidebarHitTarget,
        location: CGPoint? = nil,
        selectedGroupIdContext: UUID? = nil,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> SidebarClickResult {
        if let pendingClick,
           pendingClick.target == target,
           timestamp - pendingClick.timestamp <= Self.doubleClickInterval {
            // Distance check: only apply when both clicks provide coordinates.
            let withinDistance: Bool = {
                guard let loc = location, let prevLoc = pendingClick.location else { return true }
                let dx = loc.x - prevLoc.x
                let dy = loc.y - prevLoc.y
                return sqrt(dx * dx + dy * dy) <= Self.dragThreshold
            }()
            if withinDistance {
                self.pendingClick = nil
                return SidebarClickResult(
                    isDoubleClick: true,
                    selectedGroupIdContext: pendingClick.selectedGroupIdContext
                )
            }
        }

        pendingClick = SidebarPendingClick(
            target: target,
            location: location,
            timestamp: timestamp,
            selectedGroupIdContext: selectedGroupIdContext
        )
        return SidebarClickResult(
            isDoubleClick: false,
            selectedGroupIdContext: selectedGroupIdContext
        )
    }
}
