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
    private var trailingGroupLandscape: Bool?
    private lazy var forcedOverflowItems = UIDeferredMenuElement.uncached { completion in
        completion([])
    }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.self, environment)))
        titleCapsule.frame.size = titleCapsule.intrinsicContentSize

        for value in leadingItems + trailingItems {
            let content = AnyView(value.content
                .buttonStyle(.plain)
                .imageScale(.large)
                .fixedSize()
                .environment(\.self, environment))
            if let control = controls[value.id] {
                control.view.update(content: content)
            } else {
                let customView = WorkspaceNavigationControlView(content: content)
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
            trailingGroupLandscape = nil
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
        let isLandscape = target.view.bounds.width > target.view.bounds.height
        if trailingGroupLandscape != isLandscape {
            trailingGroups = makeTrailingGroups(for: trailingIDs, isLandscape: isLandscape)
            trailingGroupLandscape = isLandscape
        }
        for value in leadingGroup.barButtonItems {
            (value.customView as? WorkspaceNavigationControlView)?.update(
                placement: .leading,
                isLandscape: isLandscape,
                visualOffset: isLandscape ? -2 : 0
            )
        }
        for value in trailingGroups.flatMap(\.barButtonItems) {
            (value.customView as? WorkspaceNavigationControlView)?.update(
                placement: .trailing,
                isLandscape: isLandscape,
                visualOffset: isLandscape ? trailingVisualOffset(for: value) : 0
            )
        }
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
        if #available(iOS 16.0, *) {
            let needsOverflowButton = !isLandscape && trailingIDs.contains(.alternateScreen)
            item.additionalOverflowItems = needsOverflowButton ? forcedOverflowItems : nil
        }
        if item.pinnedTrailingGroup != nil {
            item.pinnedTrailingGroup = nil
        }
    }

    private func makeTrailingGroups(
        for ids: [WorkspaceNavigationBar.Item.ID],
        isLandscape: Bool
    ) -> [UIBarButtonItemGroup] {
        let warning = ids.first(where: { $0 == .alternateScreen }).flatMap { controls[$0]?.button }
        let collapsible = ids.filter { $0 != .alternateScreen }.compactMap { controls[$0]?.button }
        for item in collapsible {
            item.isHidden = false
        }
        let items = ([warning].compactMap { $0 } + collapsible)
        guard !items.isEmpty else { return [] }
        let group = UIBarButtonItemGroup(barButtonItems: items, representativeItem: nil)
        if warning != nil, !isLandscape {
            for item in collapsible {
                item.isHidden = true
            }
            group.alwaysAvailable = true
        }
        return [group]
    }

    private func trailingVisualOffset(for value: UIBarButtonItem) -> CGFloat {
        guard let id = controls.first(where: { $0.value.button === value })?.key else { return 0 }
        switch id {
        case .changes: return 3.7
        case .terminals: return 8
        default: return 0
        }
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
#endif
