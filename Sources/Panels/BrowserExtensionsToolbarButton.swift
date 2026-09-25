import AppKit
import CmuxBrowser
import SwiftUI

/// The customizable trailing area of the browser toolbar.
///
/// The layout comes from ``BrowserToolbarLayout`` (Settings, `cmux.json`
/// `browser.toolbarItems`, or the toolbar's own context menus). This view
/// observes the layout and, on macOS 15.4 or later, the extension host; the
/// buttons inside the `ForEach` receive only values and closures, so no view
/// below the list boundary holds an observable store.
struct BrowserToolbarCustomizableItems: View {
    let panel: BrowserPanel
    let compact: Bool
    let style: BrowserToolbarButtonStyle
    /// Renders a built-in button (profile, theme, design mode, DevTools).
    let builtIn: (BrowserToolbarItem) -> AnyView
    let onCustomize: () -> Void

    @AppStorage(BrowserToolbarLayout.userDefaultsKey) private var storedLayout: String?

    var body: some View {
        let layout = BrowserToolbarLayout(storedValue: storedLayout)
        if #available(macOS 15.4, *) {
            BrowserToolbarExtensionAwareItems(
                panel: panel,
                layout: layout,
                compact: compact,
                style: style,
                builtIn: builtIn,
                update: update,
                onCustomize: onCustomize
            )
        } else {
            let items = Self.visibleItems(layout.items, compact: compact, installedExtensionIDs: nil)
            ForEach(items, id: \.storageValue) { item in
                builtIn(item)
                    .contextMenu {
                        BrowserToolbarItemMenu(item: item, layout: layout, update: update, onCustomize: onCustomize)
                    }
            }
        }
    }

    private func update(_ change: (inout BrowserToolbarLayout) -> Void) {
        var layout = BrowserToolbarLayout(storedValue: storedLayout)
        change(&layout)
        storedLayout = layout == .default ? nil : layout.storedValue
    }

    /// Items to render. Compact toolbars keep design mode and DevTools in the
    /// More Actions menu; pins for extensions that are not installed, or
    /// extensions on macOS before 15.4, are skipped without being forgotten.
    static func visibleItems(
        _ items: [BrowserToolbarItem],
        compact: Bool,
        installedExtensionIDs: Set<String>?
    ) -> [BrowserToolbarItem] {
        items.filter { item in
            switch item {
            case .designMode, .devTools:
                return !compact
            case .extensions:
                return installedExtensionIDs != nil
            case .pinnedExtension(let id):
                return installedExtensionIDs?.contains(id) == true
            case .profile, .theme:
                return true
            }
        }
    }
}

/// Sizing and tint shared by toolbar buttons.
struct BrowserToolbarButtonStyle {
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let tint: Color
    let colorScheme: ColorScheme
}

/// Move, hide, unpin, and customize actions for one toolbar button.
private struct BrowserToolbarItemMenu: View {
    let item: BrowserToolbarItem
    let layout: BrowserToolbarLayout
    let update: ((inout BrowserToolbarLayout) -> Void) -> Void
    let onCustomize: () -> Void

    var body: some View {
        Button(String(localized: "browser.toolbar.moveLeft", defaultValue: "Move Left")) {
            update { $0.move(item, by: -1) }
        }
        .disabled(!layout.canMove(item, by: -1))
        Button(String(localized: "browser.toolbar.moveRight", defaultValue: "Move Right")) {
            update { $0.move(item, by: 1) }
        }
        .disabled(!layout.canMove(item, by: 1))
        if case .pinnedExtension = item {
            Button(String(localized: "browser.extensions.unpin", defaultValue: "Unpin")) {
                update { $0.hide(item) }
            }
        } else {
            Button(String(localized: "browser.toolbar.hide", defaultValue: "Hide from Toolbar")) {
                update { $0.hide(item) }
            }
        }
        Divider()
        Button(String(localized: "browser.toolbar.customize", defaultValue: "Customize Toolbar…"), action: onCustomize)
    }
}

@available(macOS 15.4, *)
private struct BrowserToolbarExtensionAwareItems: View {
    let panel: BrowserPanel
    let layout: BrowserToolbarLayout
    let compact: Bool
    let style: BrowserToolbarButtonStyle
    let builtIn: (BrowserToolbarItem) -> AnyView
    let update: ((inout BrowserToolbarLayout) -> Void) -> Void
    let onCustomize: () -> Void
    @ObservedObject private var extensions = BrowserExtensions.shared

    var body: some View {
        let actions = extensions.actionItems(for: panel)
        let actionsByID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let installedIDs = Set(extensions.installed.map(\.id))
        let items = BrowserToolbarCustomizableItems.visibleItems(layout.items, compact: compact, installedExtensionIDs: installedIDs)
        let menuModel = BrowserExtensionsMenuModel(
            actions: actions,
            pinnedIDs: Set(layout.items.compactMap { if case .pinnedExtension(let id) = $0 { return id } else { return nil } }),
            storeOfferID: storeOfferID(installedIDs: installedIDs),
            isBusy: extensions.busyID != nil,
            lastError: extensions.lastError
        )
        let panelID = panel.id
        let panel = panel
        ForEach(items, id: \.storageValue) { item in
            Group {
                switch item {
                case .extensions:
                    BrowserExtensionsToolbarButton(
                        panelID: panelID,
                        model: menuModel,
                        style: style,
                        perform: { BrowserExtensions.shared.performAction($0, in: panel) },
                        togglePin: { id in
                            update { layout in
                                let pinned = BrowserToolbarItem.pinnedExtension(id)
                                layout.setVisible(pinned, !layout.contains(pinned))
                            }
                        },
                        install: { BrowserExtensions.shared.installStoreExtension(from: $0) },
                        manage: { BrowserExtensions.shared.openManagerPage(from: panel) },
                        openStore: { BrowserExtensions.shared.openStore(from: panel) }
                    )
                case .pinnedExtension(let id):
                    if let action = actionsByID[id] {
                        BrowserPinnedExtensionButton(panelID: panelID, action: action, style: style) {
                            BrowserExtensions.shared.performAction(id, in: panel)
                        }
                    }
                default:
                    builtIn(item)
                }
            }
            .contextMenu {
                BrowserToolbarItemMenu(item: item, layout: layout, update: update, onCustomize: onCustomize)
            }
        }
    }

    private func storeOfferID(installedIDs: Set<String>) -> String? {
        guard let url = panel.currentURL,
              let id = ChromeWebStorePage.extensionID(onStorePage: url),
              !installedIDs.contains(id) else { return nil }
        return id
    }
}

/// Values the extensions menu shows; the button holds no observable state.
@available(macOS 15.4, *)
struct BrowserExtensionsMenuModel {
    let actions: [BrowserExtensions.ActionItem]
    let pinnedIDs: Set<String>
    let storeOfferID: String?
    let isBusy: Bool
    let lastError: String?
}

/// The puzzle-piece button: each loaded extension's action with a pin
/// toggle, plus `cmux://extensions` and the Chrome Web Store.
@available(macOS 15.4, *)
struct BrowserExtensionsToolbarButton: View {
    let panelID: UUID
    let model: BrowserExtensionsMenuModel
    let style: BrowserToolbarButtonStyle
    let perform: (String) -> Void
    let togglePin: (String) -> Void
    let install: (String) -> Void
    let manage: () -> Void
    let openStore: () -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            CmuxSystemSymbolImage(systemName: "puzzlepiece.extension", pointSize: style.iconPointSize, weight: .medium, tint: style.tint)
                .frame(width: style.hitSize, height: style.hitSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: style.hitSize, height: style.hitSize, alignment: .center)
        .background(BrowserExtensionsToolbarAnchor(key: .init(panelID: panelID, extensionID: nil)))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            menu.browserChromePopoverAppearance(style.colorScheme)
        }
        .safeHelp(String(localized: "browser.extensions.toolbar.help", defaultValue: "Extensions"))
        .accessibilityIdentifier("BrowserExtensionsToolbarButton")
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.actions.isEmpty {
                Text(String(localized: "browser.extensions.page.empty", defaultValue: "No extensions installed."))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            ForEach(model.actions) { item in
                HStack(spacing: 0) {
                    row(icon: item.icon, symbol: "puzzlepiece.extension", title: item.name, badge: item.badge) {
                        isPresented = false
                        perform(item.id)
                    }
                    .disabled(!item.isEnabled)
                    let pinned = model.pinnedIDs.contains(item.id)
                    Button {
                        togglePin(item.id)
                    } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .foregroundStyle(pinned ? .primary : .secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .safeHelp(pinned
                        ? String(localized: "browser.extensions.unpin", defaultValue: "Unpin")
                        : String(localized: "browser.extensions.pin", defaultValue: "Pin to Toolbar"))
                    .accessibilityIdentifier("BrowserExtensionPinButton-\(item.id)")
                    .padding(.trailing, 4)
                }
            }
            Divider().padding(.vertical, 4)
            if let storeOfferID = model.storeOfferID {
                row(symbol: "plus.circle", title: String(localized: "browser.extensions.store.add", defaultValue: "Add to cmux")) {
                    isPresented = false
                    install(storeOfferID)
                }
                .disabled(model.isBusy)
            }
            row(symbol: "gearshape", title: String(localized: "browser.extensions.toolbar.manage", defaultValue: "Manage Extensions")) {
                isPresented = false
                manage()
            }
            row(symbol: "bag", title: String(localized: "browser.extensions.page.openStore", defaultValue: "Open Chrome Web Store")) {
                isPresented = false
                openStore()
            }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    private func row(
        icon: NSImage? = nil,
        symbol: String,
        title: String,
        badge: String = "",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                BrowserExtensionIcon(icon: icon, symbol: symbol, size: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if !badge.isEmpty { BrowserExtensionBadge(text: badge) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A pinned extension's action button in the toolbar.
@available(macOS 15.4, *)
private struct BrowserPinnedExtensionButton: View {
    let panelID: UUID
    let action: BrowserExtensions.ActionItem
    let style: BrowserToolbarButtonStyle
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            ZStack(alignment: .bottomTrailing) {
                BrowserExtensionIcon(icon: action.icon, symbol: "puzzlepiece.extension", size: style.iconPointSize + 2)
                    .opacity(action.isEnabled ? 1 : 0.45)
                if !action.badge.isEmpty {
                    BrowserExtensionBadge(text: action.badge).offset(x: 5, y: 4)
                }
            }
            .frame(width: style.hitSize, height: style.hitSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: style.hitSize, height: style.hitSize, alignment: .center)
        .background(BrowserExtensionsToolbarAnchor(key: .init(panelID: panelID, extensionID: action.id)))
        .safeHelp(action.name)
        .accessibilityLabel(action.name)
        .accessibilityIdentifier("BrowserPinnedExtension-\(action.id)")
    }
}

private struct BrowserExtensionIcon: View {
    let icon: NSImage?
    let symbol: String
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct BrowserExtensionBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 3)
            .frame(minHeight: 11)
            .background(Capsule().fill(Color.secondary.opacity(0.85)))
            .foregroundStyle(.background)
            .fixedSize()
    }
}

/// A real AppKit view under a toolbar button, so an extension's popup
/// popover has something to hang from.
@available(macOS 15.4, *)
private struct BrowserExtensionsToolbarAnchor: NSViewRepresentable {
    let key: BrowserExtensions.AnchorKey

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        BrowserExtensions.shared.setAnchor(view, for: key)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        BrowserExtensions.shared.setAnchor(view, for: key)
    }
}

/// The Customize Toolbar popover: show, hide, reorder, and reset buttons.
struct BrowserToolbarCustomizationView: View {
    /// Titles for extensions that can be pinned, by id.
    let extensionNames: [(id: String, name: String)]
    @AppStorage(BrowserToolbarLayout.userDefaultsKey) private var storedLayout: String?

    private var layout: BrowserToolbarLayout { BrowserToolbarLayout(storedValue: storedLayout) }

    var body: some View {
        let layout = layout
        let candidates = BrowserToolbarItem.builtIns + extensionNames.map { BrowserToolbarItem.pinnedExtension($0.id) }
        let shown = layout.items.filter { candidates.contains($0) }
        let hidden = candidates.filter { !layout.contains($0) }
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.toolbar.customize.title", defaultValue: "Customize Toolbar"))
                .font(.headline)
            Text(String(localized: "browser.toolbar.customize.hint", defaultValue: "Drag to reorder. Uncheck a button to hide it."))
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                Section(String(localized: "browser.toolbar.customize.shown", defaultValue: "Shown")) {
                    ForEach(shown, id: \.storageValue) { item in
                        toggleRow(item, isOn: true)
                    }
                    .onMove { source, destination in
                        // Offsets are relative to `shown`; map them onto the stored list.
                        var reordered = BrowserToolbarLayout(items: shown)
                        reordered.move(fromOffsets: source, toOffset: destination)
                        let extras = layout.items.filter { !shown.contains($0) }
                        save(BrowserToolbarLayout(items: reordered.items + extras))
                    }
                }
                if !hidden.isEmpty {
                    Section(String(localized: "browser.toolbar.customize.hidden", defaultValue: "Hidden")) {
                        ForEach(hidden, id: \.storageValue) { item in
                            toggleRow(item, isOn: false)
                        }
                    }
                }
            }
            .frame(width: 280, height: 300)
            HStack {
                Spacer()
                Button(String(localized: "browser.toolbar.customize.reset", defaultValue: "Reset to Default")) {
                    storedLayout = nil
                }
                .disabled(layout == .default)
            }
        }
        .padding(12)
    }

    private func toggleRow(_ item: BrowserToolbarItem, isOn: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { visible in
                var layout = layout
                layout.setVisible(item, visible)
                save(layout)
            }
        )) {
            Text(title(for: item))
        }
        .toggleStyle(.checkbox)
    }

    private func save(_ layout: BrowserToolbarLayout) {
        storedLayout = layout == .default ? nil : layout.storedValue
    }

    private func title(for item: BrowserToolbarItem) -> String {
        switch item {
        case .designMode: return String(localized: "browser.toolbar.item.designMode", defaultValue: "Design Mode")
        case .profile: return String(localized: "browser.toolbar.item.profile", defaultValue: "Browser Profile")
        case .theme: return String(localized: "browser.toolbar.item.theme", defaultValue: "Page Theme")
        case .extensions: return String(localized: "browser.extensions.toolbar.help", defaultValue: "Extensions")
        case .devTools: return String(localized: "browser.toolbar.item.devTools", defaultValue: "Developer Tools")
        case .pinnedExtension(let id): return extensionNames.first { $0.id == id }?.name ?? id
        }
    }
}
