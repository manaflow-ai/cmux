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
        let desiredTrailingGroups = Array(trailingGroups.dropFirst())
        if !item.trailingItemGroups.elementsEqual(desiredTrailingGroups, by: { $0 === $1 }) {
            item.trailingItemGroups = desiredTrailingGroups
        }
        if #available(iOS 16.0, *) { item.additionalOverflowItems = nil }
        let desiredPinnedGroup = trailingGroups.first
        if item.pinnedTrailingGroup !== desiredPinnedGroup {
            item.pinnedTrailingGroup = desiredPinnedGroup
        }
    }

    private func makeTrailingGroups(
        for ids: [WorkspaceNavigationBar.Item.ID]
    ) -> [UIBarButtonItemGroup] {
        let groupedIDs: [[WorkspaceNavigationBar.Item.ID]]
        if ids.first == .alternateScreen {
            // A lone warning action gets UIKit's circular single-item glass.
            // Keep the count chip and terminal picker in their shared group,
            // matching the base toolbar's trailing action island.
            groupedIDs = [[.alternateScreen], Array(ids.dropFirst())]
        } else {
            groupedIDs = [ids]
        }
        return groupedIDs.compactMap { groupIDs in
            let items = groupIDs.compactMap { id in
                id == .terminals ? terminalPicker?.button : controls[id]?.button
            }
            guard !items.isEmpty else { return nil }
            // UIKit compresses the title view before laying out these
            // essential actions, instead of replacing them with More.
            return UIBarButtonItemGroup(barButtonItems: items, representativeItem: nil)
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
        let appliedTrailingGroups = Array(trailingGroups.dropFirst())
        if item.trailingItemGroups.elementsEqual(appliedTrailingGroups, by: { $0 === $1 }) {
            item.trailingItemGroups = originalItem.trailingGroups
            item.additionalOverflowItems = originalItem.additionalOverflowItems
        }
        if let pinnedGroup = trailingGroups.first, item.pinnedTrailingGroup === pinnedGroup {
            item.pinnedTrailingGroup = originalItem.trailingGroup
        }
        self.owner = nil
        self.originalItem = nil
    }

    private struct HostedControl {
        let button: UIBarButtonItem
        let view: WorkspaceNavigationControlView
    }

    @MainActor
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
