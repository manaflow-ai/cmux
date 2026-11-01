#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Screens: the workspace's screens on the Mac (its screen bar, `ScreenActionCatalog`), pushed
/// from the page menu (swipe back returns). One section per screen with its tabs; the current
/// screen (where this phone's new tabs open) is marked. A screen's menu selects, renames or
/// closes it; + makes a new one. Everything is what the Mac lists.
struct ScreensPage: View {
    let source: WorkspaceTabsSource
    @State private var screenName = ""

    var body: some View {
        content
            .navigationTitle("Screens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if source.canEditTabs {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Screen", systemImage: "plus") { Task { await source.newScreen() } }
                            .disabled(source.pendingTabTitle != nil)
                            .accessibilityIdentifier("screens.new")
                    }
                }
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .overlay(alignment: .bottom) { PageToast(source: source) }
            .alert("Rename Screen", isPresented: Binding(
                get: { source.renamingScreen != nil },
                set: { shown in if !shown { source.renamingScreen = nil } }
            ), presenting: source.renamingScreen) { screen in
                TextField(source.screenTitle(screen), text: $screenName)
                    // Names are code-like: no autocorrect, no capitals (full verify D5).
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("screens.rename.field")
                Button("Cancel", role: .cancel) {}
                Button("Rename") { Task { await source.renameScreen(screen, to: screenName) } }
                    .keyboardShortcut(.defaultAction)
            }
            // Close Screen's question when a tab on it is busy (the workspace's own is under this page).
            .alert(source.pendingClose?.title ?? "", isPresented: Binding(
                get: { source.pendingClose != nil },
                set: { shown in if !shown { source.resolvePendingClose(false) } }
            )) {
                Button("Close", role: .destructive) { source.resolvePendingClose(true) }
                Button("Cancel", role: .cancel) { source.resolvePendingClose(false) }
            } message: {
                Text(source.pendingClose?.message ?? "")
            }
            .accessibilityIdentifier("screens.page")
    }

    @ViewBuilder private var content: some View {
        if let screens = source.workspace?.screens, !screens.isEmpty {
            List {
                ForEach(Array(screens.enumerated()), id: \.element.id) { index, screen in
                    Section {
                        let tabs = source.tabs(on: screen)
                        if tabs.isEmpty {
                            Text("No tabs the iPhone shows").foregroundStyle(theme.colors.label2.color)
                        }
                        ForEach(tabs) { tab in row(tab) }
                    } header: {
                        header(screen, index: index, count: screens.count)
                    }
                }
                Section {} footer: {
                    Text("New tabs from this iPhone open on the current screen.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView("No Screens Yet", systemImage: "rectangle.stack",
                                   description: Text("\(source.macName) hasn't listed this workspace's screens."))
        }
    }

    private func header(_ screen: MacScreen, index: Int, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(screen.title(at: index)).textCase(nil)
            if screen.isActive {
                Text("Current")
                    .textCase(nil)
                    .font(theme.type.meta.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.colors.label.color.opacity(0.08), in: .capsule)
            }
            Spacer()
            if source.canEditTabs {
                Menu {
                    if !screen.isActive {
                        Button("Select Screen", systemImage: "checkmark.rectangle.stack") { Task { await source.selectScreen(screen) } }
                    }
                    Button("Rename Screen…", systemImage: "pencil") {
                        // The current name, so Rename without typing keeps it.
                        screenName = screen.name
                        source.renamingScreen = screen
                    }
                    if count > 1 {
                        Section {
                            Button("Close Screen", systemImage: "xmark.rectangle", role: .destructive) {
                                Task { await source.closeScreen(screen) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .frame(minWidth: 44, minHeight: 32)
                        .contentShape(.rect)
                }
                .accessibilityLabel("\(screen.title(at: index)) Actions")
                .accessibilityIdentifier("screens.menu.\(screen.id)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ tab: WorkspaceTab) -> some View {
        Button {
            source.activate(tab.id)
            source.route = nil
            source.openedTab = tab.id
        } label: {
            Label {
                Text(tab.title).foregroundStyle(theme.colors.label.color).lineLimit(1)
            } icon: {
                Image(systemName: tab.systemImage).foregroundStyle(theme.colors.label2.color)
            }
        }
        .accessibilityIdentifier("screens.tab.\(tab.id)")
        .accessibilityHint("Opens the tab")
    }
}
#endif
