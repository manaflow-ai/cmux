#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class WorkspaceNavigationBarController: UINavigationController {
    private let contentHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var bar: UINavigationBar { navigationBar }
    private var item: UINavigationItem { contentHost.navigationItem }
    private let titleHost = UIHostingController(rootView: AnyView(EmptyView()))
    private lazy var titleCapsule = WorkspaceNavigationTitleView(host: titleHost)
    private var controls: [WorkspaceNavigationBar.Item.ID: HostedControl] = [:]
    private var leadingIDs: [WorkspaceNavigationBar.Item.ID] = []
    private var trailingIDs: [WorkspaceNavigationBar.Item.ID] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        bar.accessibilityIdentifier = "MobileWorkspaceNavigationBar"
        bar.tintColor = .label
        bar.prefersLargeTitles = false
        contentHost.view.backgroundColor = .clear
        setViewControllers([contentHost], animated: false)

        titleHost.sizingOptions = .intrinsicContentSize
        titleHost.safeAreaRegions = []
        addChild(titleHost)
        item.style = .browser
        item.largeTitleDisplayMode = .never
        titleHost.didMove(toParent: self)
    }

    func update(
        title: AnyView,
        content: AnyView,
        backgroundColor: UIColor,
        scrollEdgeGlass: Bool,
        leadingItems: [WorkspaceNavigationBar.Item],
        trailingItems: [WorkspaceNavigationBar.Item],
        environment: EnvironmentValues
    ) {
        loadViewIfNeeded()
        overrideUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light
        view.backgroundColor = backgroundColor
        contentHost.rootView = AnyView(content.environment(\.self, environment))
        let appearance: UINavigationBarAppearance?
        if scrollEdgeGlass {
            // Preserve the system's transparent bar and scroll-edge effect.
            appearance = nil
        } else {
            let opaqueAppearance = UINavigationBarAppearance()
            opaqueAppearance.configureWithOpaqueBackground()
            opaqueAppearance.backgroundColor = backgroundColor
            appearance = opaqueAppearance
        }
        item.standardAppearance = appearance
        item.scrollEdgeAppearance = appearance
        item.compactAppearance = appearance
        item.compactScrollEdgeAppearance = appearance
        titleHost.rootView = AnyView(title.environment(\.self, environment).buttonStyle(.plain))
        titleCapsule.invalidateIntrinsicContentSize()
        // A custom title must have a natural size before the bar resizes it.
        // The bar owns the final frame between the leading and trailing items.
        titleCapsule.frame.size = titleCapsule.intrinsicContentSize
        if item.titleView !== titleCapsule {
            item.titleView = titleCapsule
        }
        titleCapsule.setNeedsLayout()

        var addedHosts: [UIHostingController<AnyView>] = []
        for value in leadingItems + trailingItems {
            let content = AnyView(value.content
                .environment(\.self, environment)
                .buttonStyle(.plain)
                .imageScale(.large)
                .fixedSize())
            if let control = controls[value.id] {
                control.host.rootView = content
                control.view.refreshContentSize()
            } else {
                let host = UIHostingController(rootView: content)
                host.sizingOptions = .intrinsicContentSize
                host.safeAreaRegions = []
                addChild(host)
                addedHosts.append(host)
                host.view.backgroundColor = .clear
                let customView = WorkspaceNavigationControlView(host: host)
                let button = UIBarButtonItem(customView: customView)
                controls[value.id] = HostedControl(host: host, button: button, view: customView)
                // The bar installs the custom view when its item array updates.
            }
        }

        let nextLeadingIDs = leadingItems.map(\.id)
        let nextTrailingIDs = trailingItems.map(\.id)
        if leadingIDs != nextLeadingIDs {
            leadingIDs = nextLeadingIDs
            item.setLeftBarButtonItems(
                leadingIDs.compactMap { controls[$0]?.button },
                animated: false
            )
        }
        if trailingIDs != nextTrailingIDs {
            trailingIDs = nextTrailingIDs
            // This group contains the actions that must remain available.
            // UIKit reserves its width before laying out the compressible title.
            item.pinnedTrailingGroup = UIBarButtonItemGroup(
                barButtonItems: trailingIDs.compactMap { controls[$0]?.button },
                representativeItem: nil
            )
        }

        let visibleIDs = Set(leadingIDs + trailingIDs)
        for id in Array(controls.keys) where !visibleIDs.contains(id) {
            guard let control = controls.removeValue(forKey: id) else { continue }
            control.host.willMove(toParent: nil)
            control.view.removeFromSuperview()
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
        let view: WorkspaceNavigationControlView
    }
}

#endif
