import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import Combine
import SwiftUI

/// Sidebar-footer lightbulb that opens a small popover with one tip at a time
/// on how to use cmux. Same size, tint, hover and popover anchor as the Help
/// button next to it. A small accent dot marks a tip the user has not seen
/// yet (at most one new tip a day, see `SidebarTipsSchedule`); the popover
/// never opens by itself.
struct SidebarTipsButton: View {
    private static let iconSize: CGFloat = 13
    private static let dotSize: CGFloat = 5

    @Environment(\.cmuxAccentColor) private var cmuxAccent
    @AppStorage(SidebarTipsStorage.currentTipIDKey) private var currentTipID = ""
    @AppStorage(SidebarTipsStorage.seenTipIDsKey) private var seenTipIDs = ""
    @AppStorage(SidebarTipsStorage.lastOpenedDayKey) private var lastOpenedDay = ""
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @State private var isPopoverPresented = false
    @State private var today = SidebarTipsSchedule.dayKey(for: Date())

    private let title = String(localized: "sidebar.tips.button", defaultValue: "Tips")

    private var tipIDs: [String] {
        SidebarTipsCatalog.visibleTips(showsModifierHoldHints: showModifierHoldHints).map(\.id)
    }

    private var progress: SidebarTipsProgress {
        SidebarTipsStorage.progress(currentTipID: currentTipID, seenTipIDs: seenTipIDs, lastOpenedDay: lastOpenedDay)
    }

    private var showsNewTipIndicator: Bool {
        !isPopoverPresented && SidebarTipsSchedule.showsNewTipIndicator(progress, tipIDs: tipIDs, today: today)
    }

    var body: some View {
        Button {
            if !isPopoverPresented {
                today = SidebarTipsSchedule.dayKey(for: Date())
                store(SidebarTipsSchedule.opened(progress, tipIDs: tipIDs, today: today))
            }
            isPopoverPresented.toggle()
        } label: {
            SidebarFooterCircularIcon(
                systemName: "lightbulb",
                style: SidebarFooterCircularIconStyle.standard.resized(to: Self.iconSize)
            )
            .frame(width: SidebarFooterButtonMetrics.buttonSize, height: SidebarFooterButtonMetrics.buttonSize)
            .overlay(alignment: .topTrailing) {
                if showsNewTipIndicator {
                    Circle()
                        .fill(cmuxAccent.color)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .padding(.top, 3)
                        .padding(.trailing, 4)
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: SidebarFooterButtonMetrics.buttonSize, height: SidebarFooterButtonMetrics.buttonSize)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            SidebarTipsPopover(showsModifierHoldHints: showModifierHoldHints)
        })
        .animation(.easeOut(duration: 0.15), value: showsNewTipIndicator)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            today = SidebarTipsSchedule.dayKey(for: Date())
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            today = SidebarTipsSchedule.dayKey(for: Date())
        }
        .accessibilityElement(children: .ignore)
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityValue(
            showsNewTipIndicator
                ? String(localized: "sidebar.tips.newTip", defaultValue: "New tip")
                : ""
        )
        .accessibilityIdentifier("SidebarTipsButton")
    }

    private func store(_ next: SidebarTipsProgress) {
        currentTipID = next.currentTipID ?? ""
        seenTipIDs = SidebarTipsStorage.encodedSeenTipIDs(next.seenTipIDs)
        lastOpenedDay = next.lastOpenedDay ?? ""
    }
}

/// The Tips popover: the tip's title with its live shortcut, one or two lines
/// of explanation, and a row to page through the other tips. Reads and writes
/// the shared progress itself so paging stays live while it is open.
private struct SidebarTipsPopover: View {
    private static let width: CGFloat = 264

    /// Passed in from the footer: the popover's own hosting view has no
    /// settings runtime in its environment.
    let showsModifierHoldHints: Bool

    @AppStorage(SidebarTipsStorage.currentTipIDKey) private var currentTipID = ""
    @AppStorage(SidebarTipsStorage.seenTipIDsKey) private var seenTipIDs = ""
    @State private var shortcutObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        let tips = SidebarTipsCatalog.visibleTips(showsModifierHoldHints: showsModifierHoldHints)
        let progress = SidebarTipsStorage.progress(currentTipID: currentTipID, seenTipIDs: seenTipIDs, lastOpenedDay: "")
        let index = min(SidebarTipsSchedule.currentIndex(progress, tipIDs: tips.map(\.id)), max(tips.count - 1, 0))
        if tips.indices.contains(index) {
            content(tips: tips, index: index)
        }
    }

    private func content(tips: [SidebarTip], index: Int) -> some View {
        let tip = tips[index]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tip.title)
                    .cmuxFont(size: 13, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let shortcut = shortcutText(for: tip) {
                    Text(shortcut)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .cmuxFont(size: 11, weight: .regular, design: .rounded)
                        .monospacedDigit()
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
            Text(tip.message)
                .cmuxFont(size: 12)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 4) {
                pageDots(count: tips.count, index: index)
                Spacer(minLength: 8)
                pageButton(
                    systemName: "chevron.left",
                    title: String(localized: "sidebar.tips.previous", defaultValue: "Previous Tip"),
                    accessibilityIdentifier: "SidebarTipsPreviousButton"
                ) {
                    select(tips[(index - 1 + tips.count) % tips.count].id)
                }
                pageButton(
                    systemName: "chevron.right",
                    title: String(localized: "sidebar.tips.next", defaultValue: "Next Tip"),
                    accessibilityIdentifier: "SidebarTipsNextButton"
                ) {
                    select(tips[(index + 1) % tips.count].id)
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: Self.width, alignment: .leading)
        .accessibilityIdentifier("SidebarTipsPopover")
    }

    private func shortcutText(for tip: SidebarTip) -> String? {
        let _ = shortcutObserver.revision
        guard let action = tip.shortcutAction else { return nil }
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound else { return nil }
        return action.displayedShortcutString(for: shortcut)
    }

    private func pageDots(count: Int, index: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { dotIndex in
                Circle()
                    .fill(Color.primary.opacity(dotIndex == index ? 0.55 : 0.18))
                    .frame(width: 4, height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private func pageButton(
        systemName: String,
        title: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            CmuxSystemSymbolImage(
                systemName: systemName,
                pointSize: 10,
                weight: .semibold,
                tint: Color(nsColor: .secondaryLabelColor)
            )
            .frame(width: 20, height: 20)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: 20, height: 20)
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func select(_ tipID: String) {
        let progress = SidebarTipsStorage.progress(currentTipID: currentTipID, seenTipIDs: seenTipIDs, lastOpenedDay: "")
        let next = SidebarTipsSchedule.selected(progress, tipID: tipID)
        currentTipID = next.currentTipID ?? ""
        seenTipIDs = SidebarTipsStorage.encodedSeenTipIDs(next.seenTipIDs)
    }
}
