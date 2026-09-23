#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class WorkspaceNavigationBarController: UIViewController {
    let bar = UINavigationBar()
    private let item = UINavigationItem()
    private let titleHost = UIHostingController(rootView: AnyView(EmptyView()))
    private lazy var titleCapsule = WorkspaceNavigationTitleView(host: titleHost)
    // This is a fixed UIKit group because these actions are part of the
    // workspace detail chrome, rather than user-customizable navigation
    // content. A nil representative deliberately keeps each action visible;
    // the titleView is the compressible part of this bar.
    private let trailingGroup = UIBarButtonItemGroup.fixedGroup(
        withRepresentativeItem: nil,
        items: []
    )
    private var controls: [WorkspaceNavigationBar.Item.ID: HostedControl] = [:]
    private var leadingIDs: [WorkspaceNavigationBar.Item.ID] = []
    private var trailingIDs: [WorkspaceNavigationBar.Item.ID] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        bar.accessibilityIdentifier = "MobileWorkspaceNavigationBar"
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.tintColor = .label
        bar.prefersLargeTitles = false
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.compactScrollEdgeAppearance = appearance
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        addChild(titleHost)
        item.largeTitleDisplayMode = .never
        item.titleView = titleCapsule
        // Unlike trailingItemGroups, this group cannot move into More.
        // Every new essential action must join this group so UIKit includes
        // its actual intrinsic width before sizing the title.
        item.pinnedTrailingGroup = trailingGroup
        bar.setItems([item], animated: false)
        titleHost.didMove(toParent: self)
    }

    func update(
        title: AnyView,
        leadingItems: [WorkspaceNavigationBar.Item],
        trailingItems: [WorkspaceNavigationBar.Item],
        environment: EnvironmentValues
    ) {
        loadViewIfNeeded()
        overrideUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light
        titleHost.rootView = AnyView(title.environment(\.self, environment).buttonStyle(.plain))
        titleCapsule.invalidateIntrinsicContentSize()
        titleCapsule.setNeedsLayout()

        var addedHosts: [UIHostingController<AnyView>] = []
        for value in leadingItems + trailingItems {
            let content = AnyView(value.content
                .environment(\.self, environment)
                .buttonStyle(.plain)
                .frame(minWidth: 30, minHeight: 44))
            if let control = controls[value.id] {
                control.host.rootView = content
                control.host.view.invalidateIntrinsicContentSize()
            } else {
                let host = UIHostingController(rootView: content)
                host.sizingOptions = .intrinsicContentSize
                addChild(host)
                addedHosts.append(host)
                host.view.backgroundColor = .clear
                host.view.setContentHuggingPriority(.required, for: .horizontal)
                host.view.setContentCompressionResistancePriority(.required, for: .horizontal)
                let button = UIBarButtonItem(customView: host.view)
                controls[value.id] = HostedControl(host: host, button: button)
                // The bar installs the custom view when its item array updates.
            }
        }

        let nextLeadingIDs = leadingItems.map(\.id)
        let nextTrailingIDs = trailingItems.map(\.id)
        if leadingIDs != nextLeadingIDs {
            leadingIDs = nextLeadingIDs
            item.setLeftBarButtonItems(leadingIDs.compactMap { controls[$0]?.button }, animated: false)
        }
        if trailingIDs != nextTrailingIDs {
            trailingIDs = nextTrailingIDs
            trailingGroup.barButtonItems = trailingIDs.compactMap { controls[$0]?.button }
        }

        let visibleIDs = Set(leadingIDs + trailingIDs)
        for id in Array(controls.keys) where !visibleIDs.contains(id) {
            guard let control = controls.removeValue(forKey: id) else { continue }
            control.host.willMove(toParent: nil)
            control.host.view.removeFromSuperview()
            control.host.removeFromParent()
        }
        for host in addedHosts {
            host.didMove(toParent: self)
        }
        bar.setNeedsLayout()
    }

    private struct HostedControl {
        let host: UIHostingController<AnyView>
        let button: UIBarButtonItem
    }
}

#endif
