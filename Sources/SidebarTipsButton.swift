import AppKit
import CoreGraphics
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebar
import SwiftUI

/// Opens short cmux tips; automatic reminders can be disabled independently.
struct SidebarTipsButton: View {
    var body: some View {
        SidebarTipsFooterButton(clock: ContinuousClock())
    }
}

private struct SidebarTipsFooterButton<C: Clock>: View where C.Duration == Duration {
    private static var iconSize: CGFloat { 13 }
    private static var dotPointSize: CGFloat { 6.5 }

    let clock: C

    @Environment(\.cmuxAccentColor) private var cmuxAccent
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage(SidebarTipsStorage.currentTipIDKey) private var currentTipID = ""
    @AppStorage(SidebarTipsStorage.seenTipIDsKey) private var seenTipIDs = ""
    @AppStorage(SidebarTipsStorage.lastOpenedDayKey) private var lastOpenedDay = ""
    @AppStorage(SidebarTipsStorage.lastOpenedAtKey) private var lastOpenedAt = 0.0
    @AppStorage(SidebarTipsStorage.automaticTipsDisabledKey) private var automaticTipsDisabled = false
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @State private var isPopoverPresented = false
    @State private var isInteracting = false
    @State private var presentationID = UUID()
    @State private var windowNumber: Int?

    private let schedule = SidebarTipsSchedule()
    private let title = String(localized: "sidebar.tips.button", defaultValue: "Tips")

    private struct AutomaticOpportunity: Equatable {
        let windowNumber: Int?
        let isActive: Bool
    }

    private struct DismissalRequest: Equatable {
        let presentationID: UUID
        let isPresented: Bool
        let isInteracting: Bool
        let tipID: String
    }

    private var tipIDs: [String] {
        SidebarTipsCatalog.visibleTips(showsModifierHoldHints: showModifierHoldHints).map(\.id)
    }

    private var progress: SidebarTipsProgress {
        SidebarTipsStorage.progress(
            currentTipID: currentTipID,
            seenTipIDs: seenTipIDs,
            lastOpenedDay: lastOpenedDay,
            automaticTipsDisabled: automaticTipsDisabled,
            lastOpenedAt: lastOpenedAt
        )
    }

    private var showsUnopenedIndicator: Bool {
        !isPopoverPresented && schedule.showsUnopenedIndicator(progress)
    }

    var body: some View {
        Button {
            if isPopoverPresented {
                isPopoverPresented = false
            } else {
                presentTip()
            }
        } label: {
            // Both glyphs are hosted symbols so the dot composites over AppKit.
            ZStack(alignment: .topTrailing) {
                SidebarFooterCircularIcon(
                    systemName: "book.closed",
                    style: SidebarFooterCircularIconStyle.standard.resized(to: Self.iconSize)
                )
                .frame(width: SidebarFooterButtonMetrics.buttonSize, height: SidebarFooterButtonMetrics.buttonSize)
                if showsUnopenedIndicator {
                    CmuxSystemSymbolImage(systemName: "circle.fill", pointSize: Self.dotPointSize, tint: cmuxAccent.color)
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                }
            }
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: SidebarFooterButtonMetrics.buttonSize, height: SidebarFooterButtonMetrics.buttonSize)
        .background(WindowAccessor { window in windowNumber = window.windowNumber })
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            SidebarTipsPopover(showsModifierHoldHints: showModifierHoldHints) { isInteracting = $0 }
        })
        .task(id: AutomaticOpportunity(windowNumber: windowNumber, isActive: controlActiveState == .key)) {
            await offerAutomaticTip()
        }
        .task(id: DismissalRequest(presentationID: presentationID, isPresented: isPopoverPresented, isInteracting: isInteracting, tipID: currentTipID)) {
            guard isPopoverPresented, !isInteracting, !NSWorkspace.shared.isVoiceOverEnabled else { return }
            do {
                // This is the intended reading deadline, owned and cancelled by SwiftUI.
                try await clock.sleep(for: .seconds(5))
                try Task.checkCancellation()
                guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
                isPopoverPresented = false
            } catch {}
        }
        .onChange(of: isPopoverPresented) { _, presented in
            if !presented { isInteracting = false }
        }
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

    private func offerAutomaticTip() async {
        guard controlActiveState == .key, windowNumber != nil,
              !isPopoverPresented, !NSWorkspace.shared.isVoiceOverEnabled,
              schedule.automaticTip(progress, tipIDs: tipIDs, now: Date()) != nil else { return }
        do {
            // One opportunity per activation, not a polling or repeating reminder.
            try await clock.sleep(for: .seconds(30))
            try Task.checkCancellation()
        } catch { return }
        guard let windowNumber, let window = NSApp.window(withWindowNumber: windowNumber),
              NSApp.isActive, window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !isPopoverPresented, !NSWorkspace.shared.isVoiceOverEnabled,
              [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel].allSatisfy({
                  CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= 30
              }),
              let tipID = schedule.automaticTip(progress, tipIDs: tipIDs, now: Date()) else { return }
        presentTip(automaticTipID: tipID)
    }

    private func presentTip(automaticTipID: String? = nil) {
        var startingProgress = progress
        if let automaticTipID { startingProgress.currentTipID = automaticTipID }
        let next = schedule.opened(startingProgress, tipIDs: tipIDs, now: Date())
        currentTipID = next.currentTipID ?? ""
        seenTipIDs = SidebarTipsStorage.encodedSeenTipIDs(next.seenTipIDs)
        lastOpenedDay = next.lastOpenedDay ?? ""
        lastOpenedAt = next.lastOpenedAt?.timeIntervalSince1970 ?? 0
        isInteracting = false
        // A transient popover may close and reopen within the same view update.
        presentationID = UUID()
        isPopoverPresented = true
    }
}

/// The Tips popover: the tip's title with its live shortcut, one or two lines
/// of explanation, a row to page through the other tips, and the automatic-tip preference. Every tip is laid out in the same stack and only the current one is
/// visible, so the popover keeps the tallest tip's height and nothing moves
/// while paging. Reads and writes the shared progress itself so paging stays
/// live while it is open.
private struct SidebarTipsPopover: View {
    private static let width: CGFloat = 264

    /// Passed in from the footer: the popover's own hosting view has no
    /// settings runtime in its environment.
    let showsModifierHoldHints: Bool
    let onInteractionChanged: (Bool) -> Void

    @AppStorage(SidebarTipsStorage.currentTipIDKey) private var currentTipID = ""
    @AppStorage(SidebarTipsStorage.seenTipIDsKey) private var seenTipIDs = ""
    @State private var shortcutObserver = KeyboardShortcutSettingsObserver.shared
    @AppStorage(SidebarTipsStorage.automaticTipsDisabledKey) private var automaticTipsDisabled = false
    @State private var isHovered = false
    @FocusState private var focusedControl: String?

    var body: some View {
        let tips = SidebarTipsCatalog.visibleTips(showsModifierHoldHints: showsModifierHoldHints)
        let progress = SidebarTipsStorage.progress(currentTipID: currentTipID, seenTipIDs: seenTipIDs, lastOpenedDay: "")
        let index = min(SidebarTipsSchedule().currentIndex(progress, tipIDs: tips.map(\.id)), max(tips.count - 1, 0))
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
            Toggle(isOn: $automaticTipsDisabled) {
                Text(String(localized: "sidebar.tips.disableAutomatic", defaultValue: "Don’t show tips automatically"))
                    .cmuxFont(size: 11)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .focused($focusedControl, equals: "automaticTips")
            .padding(.top, 6)
            .accessibilityIdentifier("SidebarTipsDisableAutomaticCheckbox")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: Self.width, alignment: .leading)
        .accessibilityIdentifier("SidebarTipsPopover")
        .onHover { hovered in
            isHovered = hovered
            onInteractionChanged(hovered || focusedControl != nil)
        }
        .onChange(of: focusedControl) { _, focused in
            onInteractionChanged(isHovered || focused != nil)
        }
        .onDisappear { onInteractionChanged(false) }
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
        .focused($focusedControl, equals: accessibilityIdentifier)
    }

    private func select(_ tipID: String) {
        let progress = SidebarTipsStorage.progress(currentTipID: currentTipID, seenTipIDs: seenTipIDs, lastOpenedDay: "")
        let next = SidebarTipsSchedule().selected(progress, tipID: tipID)
        currentTipID = next.currentTipID ?? ""
        seenTipIDs = SidebarTipsStorage.encodedSeenTipIDs(next.seenTipIDs)
    }
}
