#if os(iOS)
import SwiftUI
import UIKit

/// Configures the containing screen's native navigation item. The existing
/// navigation stack remains the sole owner of routing and content safe areas.
@MainActor
final class WorkspaceNavigationBarController: UIViewController {
    private let titleCapsule = WorkspaceNavigationTitleView()
    private var controls: [WorkspaceNavigationBar.Item.ID: HostedControl] = [:]
    private var leadingIDs: [WorkspaceNavigationBar.Item.ID] = []
    private var leadingGroup = UIBarButtonItemGroup(barButtonItems: [], representativeItem: nil)
    private var trailingIDs: [WorkspaceNavigationBar.Item.ID] = []
    private var trailingGroup = UIBarButtonItemGroup(barButtonItems: [], representativeItem: nil)
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
        leadingIDs = leadingItems.map(\.id)
        if !leadingGroup.barButtonItems.elementsEqual(nextLeadingButtons, by: { $0 === $1 }) {
            leadingGroup = UIBarButtonItemGroup(
                barButtonItems: nextLeadingButtons,
                representativeItem: nil
            )
        }
        let nextTrailingIDs = trailingItems.map(\.id)
        if trailingIDs != nextTrailingIDs {
            trailingIDs = nextTrailingIDs
            // Pin essential actions so the native bar compresses its title first.
            trailingGroup = UIBarButtonItemGroup(
                barButtonItems: trailingIDs.compactMap { controls[$0]?.button },
                representativeItem: nil
            )
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
        let orientation = navigation.view.window?.windowScene?.interfaceOrientation
        let isLandscape = orientation == .landscapeLeft || orientation == .landscapeRight
        for (id, control) in controls {
            let placement: WorkspaceNavigationControlView.Placement = leadingIDs.contains(id) ? .leading : .trailing
            let visualOffset: CGFloat
            switch id {
            case .back, .sidebar:
                visualOffset = -2
            case .changes:
                visualOffset = 4
            case .terminals:
                visualOffset = 8
            case .alternateScreen:
                visualOffset = 0
            }
            control.view.update(
                placement: placement,
                isLandscape: isLandscape,
                visualOffset: visualOffset
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
        if item.pinnedTrailingGroup !== trailingGroup {
            item.pinnedTrailingGroup = trailingGroup
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
        if item.pinnedTrailingGroup === trailingGroup {
            item.pinnedTrailingGroup = originalItem.trailingGroup
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
        let trailingGroup: UIBarButtonItemGroup?

        init(item: UINavigationItem) {
            titleView = item.titleView
            style = item.style
            largeTitleDisplayMode = item.largeTitleDisplayMode
            leadingGroups = item.leadingItemGroups
            trailingGroup = item.pinnedTrailingGroup
        }
    }
}
#endif
