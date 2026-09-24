#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class WorkspaceNavigationBarController: UIViewController {
    let bar = UINavigationBar()
    private let item = UINavigationItem()
    private let titleHost = UIHostingController(rootView: AnyView(EmptyView()))
    private lazy var titleCapsule = WorkspaceNavigationTitleView(host: titleHost)
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

        titleHost.sizingOptions = .intrinsicContentSize
        titleHost.safeAreaRegions = []
        addChild(titleHost)
        item.style = .browser
        item.largeTitleDisplayMode = .never
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
        // A custom title must have a natural size before the bar resizes it.
        // The bar owns the final frame between the leading and trailing items.
        titleCapsule.frame.size = titleCapsule.intrinsicContentSize
        if item.titleView !== titleCapsule {
            item.titleView = titleCapsule
        }
        titleCapsule.setNeedsLayout()

        var addedHosts: [UIHostingController<AnyView>] = []
        for value in leadingItems + trailingItems {
            let minimumWidth: CGFloat = switch value.id {
            case .sidebar: 44
            case .back: 52
            case .trailingCluster: 0
            case .alternateScreen, .changes, .terminals: 30
            }
            let content = AnyView(value.content
                .environment(\.self, environment)
                .buttonStyle(.plain)
                .frame(minWidth: minimumWidth, minHeight: 36)
                .fixedSize())
            if let control = controls[value.id] {
                control.host.rootView = content
                control.host.view.invalidateIntrinsicContentSize()
                control.width.constant = control.host.sizeThatFits(in: UIView.layoutFittingExpandedSize).width
            } else {
                let host = UIHostingController(rootView: content)
                host.sizingOptions = .intrinsicContentSize
                host.safeAreaRegions = []
                addChild(host)
                addedHosts.append(host)
                host.view.backgroundColor = .clear
                host.view.setContentHuggingPriority(.required, for: .horizontal)
                host.view.setContentCompressionResistancePriority(.required, for: .horizontal)
                host.view.translatesAutoresizingMaskIntoConstraints = false
                let width = host.view.widthAnchor.constraint(
                    equalToConstant: host.sizeThatFits(in: UIView.layoutFittingExpandedSize).width
                )
                width.isActive = true
                let button = UIBarButtonItem(customView: host.view)
                controls[value.id] = HostedControl(host: host, button: button, width: width)
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
        let width: NSLayoutConstraint
    }
}

#endif
