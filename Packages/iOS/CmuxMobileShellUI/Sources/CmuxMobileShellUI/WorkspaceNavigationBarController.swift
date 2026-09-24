#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class WorkspaceNavigationBarController: UINavigationController {
    private let contentHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let barScrollAnchor = UIScrollView()
    private var bar: UINavigationBar { navigationBar }
    private var item: UINavigationItem { contentHost.navigationItem }
    private let titleCapsule = WorkspaceNavigationTitleView()
    private var controls: [WorkspaceNavigationBar.Item.ID: HostedControl] = [:]
    private var leadingIDs: [WorkspaceNavigationBar.Item.ID] = []
    private var trailingIDs: [WorkspaceNavigationBar.Item.ID] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        bar.accessibilityIdentifier = "MobileWorkspaceNavigationBar"
        bar.tintColor = .label
        bar.prefersLargeTitles = false
        bar.insetsLayoutMarginsFromSafeArea = false
        bar.directionalLayoutMargins = .zero
        contentHost.view.backgroundColor = .clear
        setViewControllers([contentHost], animated: false)
        // Preserve the existing pinned bar on browser/chat surfaces. Owning
        // the controller lets us set this public association directly.
        barScrollAnchor.isScrollEnabled = false
        contentHost.setContentScrollView(barScrollAnchor, for: .top)

        item.style = .browser
        item.largeTitleDisplayMode = .never
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
        titleCapsule.update(content: AnyView(title
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.self, environment)))
        titleCapsule.invalidateIntrinsicContentSize()
        // A custom title must have a natural size before the bar resizes it.
        // The bar owns the final frame between the leading and trailing items.
        titleCapsule.frame.size = titleCapsule.intrinsicContentSize
        if item.titleView !== titleCapsule {
            item.titleView = titleCapsule
        }
        titleCapsule.setNeedsLayout()

        for value in leadingItems + trailingItems {
            let minimumWidth: CGFloat = switch value.id {
            case .sidebar, .back: 52
            case .alternateScreen: 41.3
            case .changes: 55.3
            case .terminals: 42.3
            }
            let content = AnyView(value.content
                .buttonStyle(.plain)
                .imageScale(.large)
                .fixedSize()
                .environment(\.self, environment))
            if let control = controls[value.id] {
                control.view.update(content: content)
            } else {
                let customView = WorkspaceNavigationControlView(content: content, minimumWidth: minimumWidth)
                let button = UIBarButtonItem(customView: customView)
                button.width = minimumWidth
                controls[value.id] = HostedControl(button: button, view: customView)
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
            control.view.removeFromSuperview()
        }
        bar.setNeedsLayout()
    }

    private struct HostedControl {
        let button: UIBarButtonItem
        let view: WorkspaceNavigationControlView
    }
}

#endif
