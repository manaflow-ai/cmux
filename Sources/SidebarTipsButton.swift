import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// Sidebar-footer lightbulb that opens a small popover with one tip at a time
/// on how to use cmux. Same size, tint, hover and popover anchor as the Help
/// button next to it. A small accent dot sits on the bulb until the popover is
/// opened for the first time (see `SidebarTipsSchedule`); the popover never
/// opens by itself. "Don't show again" hides the button until the Help
/// popover's "Show Tips" brings it back.
struct SidebarTipsButton: View {
    private static let iconSize: CGFloat = 13
    private static let dotSize: CGFloat = 6
    /// Gap knocked out of the glyph around the dot so it reads on any backdrop.
    private static let dotRing: CGFloat = 1.5
    private static let dotTopInset: CGFloat = 2.5
    private static let dotTrailingInset: CGFloat = 3

    @Environment(\.cmuxAccentColor) private var cmuxAccent
    @AppStorage(SidebarTipsStorage.currentTipIDKey) private var currentTipID = ""
    @AppStorage(SidebarTipsStorage.seenTipIDsKey) private var seenTipIDs = ""
    @AppStorage(SidebarTipsStorage.lastOpenedDayKey) private var lastOpenedDay = ""
    @AppStorage(SidebarTipsStorage.hiddenKey) private var isHidden = false
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @State private var isPopoverPresented = false

    private let title = String(localized: "sidebar.tips.button", defaultValue: "Tips")

    private var tipIDs: [String] {
        SidebarTipsCatalog.visibleTips(showsModifierHoldHints: showModifierHoldHints).map(\.id)
    }

    private var progress: SidebarTipsProgress {
        SidebarTipsStorage.progress(
            currentTipID: currentTipID,
            seenTipIDs: seenTipIDs,
            lastOpenedDay: lastOpenedDay,
            isHidden: isHidden
        )
    }

    private var showsUnopenedIndicator: Bool {
        !isPopoverPresented && SidebarTipsSchedule.showsUnopenedIndicator(progress)
    }

    var body: some View {
        if SidebarTipsSchedule.showsButton(progress) {
            button
        }
    }

    private var button: some View {
        Button {
            if !isPopoverPresented {
                let today = SidebarTipsSchedule.dayKey(for: Date())
                store(SidebarTipsSchedule.opened(progress, tipIDs: tipIDs, today: today))
            }
            isPopoverPresented.toggle()
        } label: {
            SidebarFooterCircularIcon(
                systemName: "lightbulb",
                style: SidebarFooterCircularIconStyle.standard.resized(to: Self.iconSize)
            )
            .frame(width: SidebarFooterButtonMetrics.buttonSize, height: SidebarFooterButtonMetrics.buttonSize)
            .mask { glyphMask }
            .overlay(alignment: .topTrailing) {
                if showsUnopenedIndicator {
                    Circle()
                        .fill(cmuxAccent.color)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .padding(.top, Self.dotTopInset)
                        .padding(.trailing, Self.dotTrailingInset)
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
            SidebarTipsPopover(showsModifierHoldHints: showModifierHoldHints) {
                isPopoverPresented = false
                isHidden = true
            }
        })
        .animation(.easeOut(duration: 0.15), value: showsUnopenedIndicator)
        .accessibilityElement(children: .ignore)
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityValue(
            showsUnopenedIndicator
                ? String(localized: "sidebar.tips.newTip", defaultValue: "New tip")
                : ""
        )
        .accessibilityIdentifier("SidebarTipsButton")
    }

    /// Opaque everywhere except a small circle behind the dot, so the bulb
    /// glyph keeps a clean gap around it.
    private var glyphMask: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
            if showsUnopenedIndicator {
                Circle()
                    .frame(width: Self.dotSize + Self.dotRing * 2, height: Self.dotSize + Self.dotRing * 2)
                    .padding(.top, Self.dotTopInset - Self.dotRing)
                    .padding(.trailing, Self.dotTrailingInset - Self.dotRing)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }

    private func store(_ next: SidebarTipsProgress) {
        currentTipID = next.currentTipID ?? ""
        seenTipIDs = SidebarTipsStorage.encodedSeenTipIDs(next.seenTipIDs)
        lastOpenedDay = next.lastOpenedDay ?? ""
    }
}

/// "Show Tips" row for the Help popover. It only appears while the Tips
/// button is hidden by "Don't show again", and matches the other Help rows.
struct SidebarTipsHelpMenuItem: View {
    let dismissHelpPopover: () -> Void

    @AppStorage(SidebarTipsStorage.hiddenKey) private var isHidden = false

    var body: some View {
        if isHidden {
            Button {
                dismissHelpPopover()
                isHidden = false
            } label: {
                HStack(spacing: 8) {
                    Text(String(localized: "sidebar.help.showTips", defaultValue: "Show Tips"))
                        .cmuxFont(size: 12)
                    Spacer(minLength: 0)
                    CmuxSystemSymbolImage(
                        systemName: "lightbulb",
                        pointSize: 13,
                        tint: Color(nsColor: .secondaryLabelColor)
                    )
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SidebarHelpMenuOptionShowTips")
        }
    }
}

/// The Tips popover: the tip's title with its live shortcut, one or two lines
/// of explanation, a row to page through the other tips, and "Don't show
/// again". Every tip is laid out in the same stack and only the current one is
/// visible, so the popover keeps the tallest tip's height and nothing moves
/// while paging. Reads and writes the shared progress itself so paging stays
/// live while it is open.
private struct SidebarTipsPopover: View {
    private static let width: CGFloat = 264

    /// Passed in from the footer: the popover's own hosting view has no
    /// settings runtime in its environment.
    let showsModifierHoldHints: Bool
    let onDontShowAgain: () -> Void

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
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(tips.enumerated()), id: \.element.id) { tipIndex, tip in
                    tipText(tip)
                        .opacity(tipIndex == index ? 1 : 0)
                        .accessibilityHidden(tipIndex != index)
                }
            }
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
            Button(action: onDontShowAgain) {
                Text(String(localized: "sidebar.tips.dontShowAgain", defaultValue: "Don’t show again"))
                    .cmuxFont(size: 11)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityIdentifier("SidebarTipsDontShowAgainButton")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: Self.width, alignment: .leading)
        .accessibilityIdentifier("SidebarTipsPopover")
    }

    private func tipText(_ tip: SidebarTip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
