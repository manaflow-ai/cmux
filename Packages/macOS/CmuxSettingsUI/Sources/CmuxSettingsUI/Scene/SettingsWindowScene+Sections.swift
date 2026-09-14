import SwiftUI

/// The settings detail stack, split out of `SettingsWindowScene.swift`.
/// Sections mount progressively through ``SettingsSectionMountModel``
/// (https://github.com/manaflow-ai/cmux/issues/12134): the one the window
/// opens on in the first layout pass, the rest one per run-loop turn.
extension SettingsWindowRoot {
    /// Sections a window opening now mounts progressively. Cloud stays
    /// eager while unavailable: it renders nothing, so a placeholder would
    /// only advertise a section the sidebar hides.
    static func mountOrder(cloudAvailable: Bool) -> [SettingsSectionID] {
        SettingsSectionMountModel.displayOrder.filter { $0 != .cloudMachines || cloudAvailable }
    }

    func anchorID(for section: SettingsSectionID) -> String {
        "section:\(section.rawValue)"
    }

    @ViewBuilder
    func sectionStack(proxy: ScrollViewProxy) -> some View {
        // Order matches the legacy in-app SettingsView scroll order:
        // Account, App, Terminal, TextBox, Mobile, Sidebar, Beta Features,
        // Automation, Browser (with embedded Import), Global Hotkey,
        // Keyboard Shortcuts, Workspace Colors, cmux.json, Reset.
        slot(.account, proxy: proxy) {
            AccountSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                accountFlow: accountFlow
            )
        }

        slot(.app, proxy: proxy) {
            AppSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                hostActions: hostActions
            )
        }

        slot(.terminal, proxy: proxy) {
            TerminalSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                hostActions: hostActions
            )
        }

        slot(.textBox, proxy: proxy) {
            TextBoxSection(defaultsStore: defaultsStore, catalog: catalog)
        }

        slot(.sleepyMode, proxy: proxy) {
            SleepyModeSection(hostActions: hostActions, store: hostActions.sleepyModeStore())
        }

        slot(.mobile, proxy: proxy) {
            MobileSection(defaultsStore: defaultsStore, catalog: catalog, hostActions: hostActions)
        }

        slot(.cloudMachines, proxy: proxy) {
            // `DisableCloud` (MDM) and the rollout gate: no Cloud pane at all
            // while unavailable, not just no placeholder.
            if isCloudSectionAvailable {
                CloudMachinesSection(hostActions: hostActions)
            }
        }

        slot(.networking, proxy: proxy) {
            IrohNetworkingSection(hostActions: hostActions)
        }

        slot(.sidebarAppearance, proxy: proxy) {
            SidebarSection(defaultsStore: defaultsStore, catalog: catalog, hostActions: hostActions)
        }

        slot(.customSidebars, proxy: proxy) {
            CustomSidebarsSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog
            )
        }

        slot(.betaFeatures, proxy: proxy) {
            BetaFeaturesSection(defaultsStore: defaultsStore, catalog: catalog)
        }

        slot(.automation, proxy: proxy) {
            AutomationSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                secretStore: secretStore,
                catalog: catalog,
                errorLog: runtime.errorLog,
                hostActions: hostActions
            )
        }

        slot(.computerUse, proxy: proxy) {
            ComputerUseSection(
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog,
                hostActions: hostActions
            )
        }

        slot(.browser, proxy: proxy) {
            BrowserSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                hostActions: hostActions,
                importAnchorID: anchorID(for: .browserImport)
            )
        }

        slot(.globalHotkey, proxy: proxy) {
            GlobalHotkeySection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog, errorLog: runtime.errorLog,
                hostActions: hostActions,
                defaultShortcutResolver: runtime.shortcutDefaultResolver
            )
        }

        slot(.keyboardShortcuts, proxy: proxy) {
            KeyboardShortcutsSection(
                jsonStore: jsonStore, userDefaultsStore: defaultsStore,
                catalog: catalog,
                errorLog: runtime.errorLog,
                hostActions: hostActions,
                defaultShortcutResolver: runtime.shortcutDefaultResolver
            )
        }

        slot(.workspaceColors, proxy: proxy) {
            WorkspaceColorsSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog
            )
        }

        slot(.settingsJSON, proxy: proxy) {
            SettingsJSONSection(jsonStore: jsonStore, hostActions: hostActions)
        }

        slot(.reset, proxy: proxy) {
            ResetSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                hostActions: hostActions
            )
        }
    }

    private func slot<Content: View>(
        _ section: SettingsSectionID,
        proxy: ScrollViewProxy,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsSectionSlot(
            section: section,
            isMounted: mountModel.isMounted(section),
            showsPlaceholder: section != .cloudMachines || isCloudSectionAvailable,
            onMountedAppear: { sectionContentDidAppear(section, proxy: proxy) },
            content: content
        )
    }

    /// A mounted section's content is in the hierarchy: `onAppear` runs
    /// inside the update that laid it out, before that frame commits.
    /// `scrollTo` resolves against the layout that exists when it is called,
    /// so this is the moment to scroll: a navigation deferred to this
    /// section can reach its rows now, and if the section sits above the
    /// pinned navigation its growth just pushed the pinned anchor down, so
    /// the pin is re-applied here and the committed frame never shows the
    /// shift. The next section then mounts one main-actor hop later — a
    /// later update pass — so every section is built in a pass of its own
    /// and input queued meanwhile is serviced first.
    func sectionContentDidAppear(_ section: SettingsSectionID, proxy: ScrollViewProxy) {
        if let deferred = mountModel.takeDeferredScroll(for: section),
           deferred.generation == settingsNavigationGeneration {
            proxy.scrollTo(deferred.anchorID, anchor: deferred.anchor)
        } else if let pin = mountModel.pinnedScroll, mountModel.isAbove(section, pin.section) {
            proxy.scrollTo(pin.anchorID, anchor: pin.anchor)
        }
        Task { @MainActor in
            _ = mountModel.sectionDidAppear(section)
        }
    }
}
