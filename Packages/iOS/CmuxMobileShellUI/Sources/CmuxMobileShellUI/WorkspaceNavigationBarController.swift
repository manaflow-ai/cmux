#if os(iOS)
import SwiftUI
import UIKit

/// Configures the containing screen's native navigation item. The existing
/// navigation stack remains the sole owner of routing and content safe areas.
@MainActor
final class WorkspaceNavigationBarController: UIViewController {
    private let titleCapsule = WorkspaceNavigationTitleView()
    private var controls: [WorkspaceNavigationBar.Item.ID: HostedControl] = [:]
    private var leadingGroup = UIBarButtonItemGroup(barButtonItems: [], representativeItem: nil)
    private var trailingIDs: [WorkspaceNavigationBar.Item.ID] = []
    private var trailingGroups: [UIBarButtonItemGroup] = []
    private var terminalPicker: TerminalPickerBarItem?
    private weak var owner: UIViewController?
    private var originalItem: OriginalItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        applyConfiguration()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyConfiguration()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        applyConfiguration()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyConfiguration()
    }

    func update(
        title: AnyView,
        leadingItems: [WorkspaceNavigationBar.Item],
        trailingItems: [WorkspaceNavigationBar.Item],
        environment: EnvironmentValues
    ) {
        loadViewIfNeeded()
        titleCapsule.update(content: AnyView(title
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
            .environment(\.self, environment)))
        titleCapsule.frame.size = titleCapsule.intrinsicContentSize

        for value in leadingItems + trailingItems {
            guard case .custom(let customContent) = value.content else {
                if case let .terminals(value, actions) = value.content {
                    if let terminalPicker {
                        terminalPicker.update(value: value, actions: actions)
                    } else {
                        terminalPicker = TerminalPickerBarItem(value: value, actions: actions)
                    }
                }
                continue
            }
            let itemWidth = WorkspaceNavigationControlView.width(for: value.id)
            let content = AnyView(WorkspaceNavigationControlContent(
                content: customContent,
                width: itemWidth
            ).environment(\.self, environment))
            if let control = controls[value.id] {
                control.view.update(content: content)
            } else {
                let customView = WorkspaceNavigationControlView(
                    content: content,
                    width: itemWidth
                )
                controls[value.id] = HostedControl(
                    button: UIBarButtonItem(customView: customView), view: customView
                )
            }
        }
        let nextLeadingButtons = leadingItems.compactMap { controls[$0.id]?.button }
        if !leadingGroup.barButtonItems.elementsEqual(nextLeadingButtons, by: { $0 === $1 }) {
            leadingGroup = UIBarButtonItemGroup(
                barButtonItems: nextLeadingButtons,
                representativeItem: nil
            )
        }
        let nextTrailingIDs = trailingItems.map(\.id)
        if trailingIDs != nextTrailingIDs {
            trailingIDs = nextTrailingIDs
            trailingGroups = makeTrailingGroups(for: nextTrailingIDs)
        }
        let visibleIDs = Set((leadingItems + trailingItems).map(\.id))
        controls = controls.filter { visibleIDs.contains($0.key) }
        applyConfiguration()
    }

    private func applyConfiguration() {
        // Public view-controller containment identifies this screen's item.
        // Never configure another screen via navigationController.topViewController.
        var ancestor = parent
        while let candidate = ancestor, !(candidate.parent is UINavigationController) {
            ancestor = candidate.parent
        }
        guard let target = ancestor, let navigation = target.parent as? UINavigationController else { return }
        if owner !== target {
            restoreConfiguration()
            owner = target
            originalItem = OriginalItem(item: target.navigationItem)
        }
        let item = target.navigationItem
        navigation.navigationBar.accessibilityIdentifier = "MobileWorkspaceNavigationBar"
        item.style = .browser
        item.largeTitleDisplayMode = .never
        if item.titleView !== titleCapsule {
            item.titleView = titleCapsule
        }
        let desiredLeadingGroups = leadingGroup.barButtonItems.isEmpty ? [] : [leadingGroup]
        if !item.leadingItemGroups.elementsEqual(desiredLeadingGroups, by: { $0 === $1 }) {
            item.leadingItemGroups = desiredLeadingGroups
        }
        if !item.trailingItemGroups.elementsEqual(trailingGroups, by: { $0 === $1 }) {
            item.trailingItemGroups = trailingGroups
        }
        if #available(iOS 16.0, *) { item.additionalOverflowItems = nil }
        if item.pinnedTrailingGroup != nil {
            item.pinnedTrailingGroup = nil
        }
    }

    private func makeTrailingGroups(
        for ids: [WorkspaceNavigationBar.Item.ID]
    ) -> [UIBarButtonItemGroup] {
        let warning = ids.first(where: { $0 == .alternateScreen }).flatMap { controls[$0]?.button }
        let representative = ids.first(where: { $0 == .overflow }).flatMap { controls[$0]?.button }
        let collapsible = ids
            .filter { $0 != .alternateScreen && $0 != .overflow }
            .compactMap { id in id == .terminals ? terminalPicker?.button : controls[id]?.button }
        var groups: [UIBarButtonItemGroup] = []
        if let warning {
            groups.append(UIBarButtonItemGroup(barButtonItems: [warning], representativeItem: nil))
        }
        if !collapsible.isEmpty {
            // UIKit swaps this representative item for the group when the
            // actual navigation-bar space is insufficient. The overflow
            // decision therefore follows the bar's layout, not orientation.
            groups.append(UIBarButtonItemGroup(
                barButtonItems: collapsible,
                representativeItem: representative
            ))
        }
        return groups
    }

    func restoreConfiguration() {
        guard let owner, let originalItem else { return }
        let item = owner.navigationItem
        if item.titleView === titleCapsule {
            item.titleView = originalItem.titleView
            item.style = originalItem.style
            item.largeTitleDisplayMode = originalItem.largeTitleDisplayMode
        }
        if item.leadingItemGroups.elementsEqual([leadingGroup], by: { $0 === $1 }) {
            item.leadingItemGroups = originalItem.leadingGroups
        }
        if item.trailingItemGroups.elementsEqual(trailingGroups, by: { $0 === $1 }) {
            item.trailingItemGroups = originalItem.trailingGroups
            item.additionalOverflowItems = originalItem.additionalOverflowItems
        }
        if item.pinnedTrailingGroup == nil, let trailingGroup = originalItem.trailingGroup {
            item.pinnedTrailingGroup = trailingGroup
        }
        self.owner = nil
        self.originalItem = nil
    }

    private struct HostedControl {
        let button: UIBarButtonItem
        let view: WorkspaceNavigationControlView
    }

    private struct OriginalItem {
        let titleView: UIView?
        let style: UINavigationItem.ItemStyle
        let largeTitleDisplayMode: UINavigationItem.LargeTitleDisplayMode
        let leadingGroups: [UIBarButtonItemGroup]
        let trailingGroups: [UIBarButtonItemGroup]
        let trailingGroup: UIBarButtonItemGroup?
        let additionalOverflowItems: UIDeferredMenuElement?

        init(item: UINavigationItem) {
            titleView = item.titleView
            style = item.style
            largeTitleDisplayMode = item.largeTitleDisplayMode
            leadingGroups = item.leadingItemGroups
            trailingGroups = item.trailingItemGroups
            trailingGroup = item.pinnedTrailingGroup
            additionalOverflowItems = item.additionalOverflowItems
        }
    }
}

private struct WorkspaceNavigationControlContent: View {
    let content: AnyView
    let width: CGFloat

    var body: some View {
        ZStack {
            content
        }
        .buttonStyle(.plain)
        .imageScale(.large)
        .frame(width: width, height: 36)
    }
}
#endif
