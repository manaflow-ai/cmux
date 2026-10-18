import AppKit
import CmuxCloud
import CmuxFoundation
import CmuxSurfaceCatalogModel
import SwiftUI

/// The share menu's rows for one port, as values. The preview tab's share
/// control and the Ports row's Share submenu render the same model, so the two
/// entry points can never offer different choices.
struct CloudPortShareMenuModel: Equatable {
    enum Action: Equatable {
        case change(CloudPortShareTarget)
        case copyLink
    }

    struct Row: Equatable {
        let title: String
        let symbolName: String?
        let isChecked: Bool
        let isEnabled: Bool
        let isDestructive: Bool
        let action: Action?
    }

    /// The disabled first line: who can open the port right now.
    let status: String
    /// The audience rows (Only you · Team · Anyone with the link).
    let audiences: [Row]
    /// Copy Link and Stop Sharing; both need a link.
    let linkActions: [Row]

    init(plan: CloudPortSharePlan, hasLoaded: Bool) {
        status = hasLoaded
            ? CloudTreePortPresentation.sharingStatus(plan.current)
            : String(localized: "cloudPort.share.checking", defaultValue: "Checking who can open this port\u{2026}")
        let selected = hasLoaded ? plan.selectedAudience : nil
        audiences = CloudPortShareAudience.allCases.map { audience in
            // A choice that still asks for confirmation says so with an ellipsis.
            let asks = plan.requiresPublicConfirmation(.audience(audience))
            return Row(
                title: asks ? audience.menuTitle + "\u{2026}" : audience.menuTitle,
                symbolName: audience.symbolName,
                isChecked: selected == audience,
                isEnabled: hasLoaded,
                isDestructive: false,
                action: .change(.audience(audience))
            )
        }
        let shared = hasLoaded && plan.isShared
        linkActions = [
            Row(
                title: String(localized: "cloudPort.share.copyLink", defaultValue: "Copy Link"),
                symbolName: "link",
                isChecked: false,
                isEnabled: shared,
                isDestructive: false,
                action: .copyLink
            ),
            Row(
                title: String(localized: "cloudPort.share.stop", defaultValue: "Stop Sharing"),
                symbolName: "xmark.circle",
                isChecked: false,
                isEnabled: shared,
                isDestructive: true,
                action: .change(.stopSharing)
            ),
        ]
    }
}

extension CloudPortShareFlow {
    /// The share menu for `context`, read from the shared store. Asking for it
    /// also asks the store for a refresh, which its freshness policy bounds.
    static func menuItems(_ context: CloudPortShareContext) -> [NSMenuItem] {
        let store = CloudPortSharingStore.shared
        store.requestRefresh()
        let model = CloudPortShareMenuModel(
            plan: store.plan(machineID: context.machineID, port: context.port),
            hasLoaded: store.hasLoaded
        )
        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        var items: [NSMenuItem] = [status, .separator()]
        items += model.audiences.map { menuItem($0, context: context) }
        items.append(.separator())
        items += model.linkActions.map { menuItem($0, context: context) }
        return items
    }

    private static func menuItem(_ row: CloudPortShareMenuModel.Row, context: CloudPortShareContext) -> NSMenuItem {
        let item = CloudTreeMenuItem(title: row.title) {
            switch row.action {
            case .change(let target)?: change(context, to: target)
            case .copyLink?: copyLink(context)
            case nil: break
            }
        }
        item.state = row.isChecked ? .on : .off
        item.isEnabled = row.isEnabled
        if let symbol = row.symbolName {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if row.isDestructive, row.isEnabled {
            // Red text, like the browser's destructive data action; never preselected.
            item.attributedTitle = NSAttributedString(string: row.title, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.menuFont(ofSize: 0),
            ])
        }
        return item
    }
}

/// The trailing audience badge on a Cloud port row: a glyph and one quiet word.
/// It reads the shared store, so it changes as soon as a share change lands,
/// and stays empty until the first read rather than claiming "Private".
struct CloudPortAudienceBadgeView: View {
    let machineID: String
    let port: Int
    let style: CloudTreeStyle
    private var store: CloudPortSharingStore { .shared }

    var body: some View {
        Group {
            if let badge = CloudTreePortPresentation.audienceBadge(store.sharing(machineID: machineID, port: port)) {
                HStack(spacing: 3) {
                    Image(systemName: badge.symbolName)
                        .font(.system(size: max(8, style.detailSize - 2), weight: .medium))
                    Text(badge.title)
                        .cmuxFont(size: style.detailSize, design: style.fontDesign)
                        .lineLimit(1)
                }
                .foregroundStyle(badge.kind == .public ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(badge.help)
            }
        }
        .onAppear { store.requestRefresh() }
    }
}

/// The preview tab's share control: a compact pill in the address bar naming
/// the port's audience, opening the shared share menu on click.
struct CloudPortShareToolbarControl: View {
    let context: CloudPortShareContext
    let iconPointSize: CGFloat
    let height: CGFloat
    let tint: Color
    private var store: CloudPortSharingStore { .shared }

    private var badge: CloudPortAudienceBadge? {
        CloudTreePortPresentation.audienceBadge(store.sharing(machineID: context.machineID, port: context.port))
    }

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 4) {
                CmuxSystemSymbolImage(
                    systemName: badge?.symbolName ?? "square.and.arrow.up",
                    pointSize: max(9, iconPointSize - 2),
                    weight: .medium,
                    tint: badge?.kind == .public ? .orange : tint
                )
                Text(badge?.title ?? String(localized: "cloudPort.share.toolbar.share", defaultValue: "Share"))
                    .cmuxFont(size: 11, weight: .medium)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(badge?.kind == .public ? Color.orange : tint)
            .padding(.horizontal, 7)
            .frame(height: height)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .safeHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier("BrowserCloudPortShareButton")
        .onAppear { store.requestRefresh() }
    }

    private var helpText: String {
        let status = badge?.help ?? CloudTreePortPresentation.sharingStatus(nil)
        return String(
            format: String(localized: "cloudPort.share.toolbar.help", defaultValue: "%1$@\nShare %2$@ with your team or anyone with the link."),
            status,
            context.portLabel
        )
    }

    /// Pops the native menu under the pointer's click, like the browser's other
    /// toolbar menus; the menu itself is AppKit so checkmarks and the red Stop
    /// Sharing row render natively.
    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in CloudPortShareFlow.menuItems(context) { menu.addItem(item) }
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
    }
}
