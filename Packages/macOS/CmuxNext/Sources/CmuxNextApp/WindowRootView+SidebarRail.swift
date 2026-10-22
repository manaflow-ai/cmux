import AppKit
import CmuxNextDesign
import CmuxNextSidebar

// `sidebar.style` = rail (plans/cmux-next/minimal-sidebar.md): the content and the title sit beside
// the rail (`SidebarModel.contentInset`), pinned to the window edge rather than to the sidebar, so
// the rail's full sidebar opens over them and no terminal resizes. The standard style keeps the
// side pins (`SidebarSide.pins`). The pins are found by identifier: no stored state here.
extension WindowRootView {
    private static let railPinID = "sidebar.rail.pin"

    /// The side pins that tie the content or the title to the sidebar's inner edge.
    private var sidebarEdgePins: [NSLayoutConstraint] {
        (sidePins[sidebarSide] ?? []).filter { $0.secondItem === sidebar && $0.firstItem !== sidebar }
    }

    /// Swaps between the side pins and the rail pins for the current style and side, and sets the
    /// rail pins' insets. Idempotent; runs on a style, side, presentation or gutter change.
    func applySidebarRail() {
        let rail = sidebar.model.style == .rail
        let existing = constraints.filter { $0.identifier == Self.railPinID }
        let wanted = rail ? railPins(existing: existing) : []
        NSLayoutConstraint.deactivate(existing.filter { old in !wanted.contains { $0 === old } })
        if rail {
            NSLayoutConstraint.deactivate(sidebarEdgePins.filter(\.isActive))
            NSLayoutConstraint.activate(wanted.filter { !$0.isActive })
        } else {
            NSLayoutConstraint.activate(sidebarEdgePins.filter { !$0.isActive })
        }
    }

    /// This side's rail pins (reused when present), with their constants set.
    private func railPins(existing: [NSLayoutConstraint]) -> [NSLayoutConstraint] {
        let inset = sidebar.model.contentInset, gutter = Metrics.mainPaneGutter
        func pin(_ item: NSView, _ attribute: NSLayoutConstraint.Attribute, constant: CGFloat,
                 priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
            let found = existing.first { $0.firstItem === item && $0.firstAttribute == attribute }
            let constraint = found ?? {
                let anchor = NSLayoutConstraint(item: item, attribute: attribute, relatedBy: .equal, toItem: self,
                                                attribute: attribute, multiplier: 1, constant: constant)
                anchor.identifier = Self.railPinID
                anchor.priority = priority
                return anchor
            }()
            constraint.constant = constant
            return constraint
        }
        // The same priorities as the side pins they stand in for: the title still yields to the
        // traffic-light inset.
        return switch sidebarSide {
        case .left: [pin(contentHost, .leading, constant: inset + gutter, priority: .required - 2),
                     pin(titlebar, .leading, constant: inset, priority: .required - 1)]
        case .right: [pin(contentHost, .trailing, constant: -(inset + gutter), priority: .required - 2),
                      pin(titlebar, .trailing, constant: -inset, priority: .required - 1)]
        }
    }
}
