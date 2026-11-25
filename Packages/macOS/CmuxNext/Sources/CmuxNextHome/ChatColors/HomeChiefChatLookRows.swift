public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextSettings
import os

/// The Chief chat's look in the Chief Settings popover's Appearance section (Leo 2026-10-20: "being
/// able to opt into themed messages and whatnot ... it's just so awkward"): Bubble Style (iMessage or
/// Theme, `home.chiefBubbleStyle`) and Chat Colors, which opens the same Chat Colors… panel as the
/// chat row's right-click. The style is read and written through the same `SettingsController` as
/// Settings > Home > Chief Chat > Bubble Style, so a change in either shows in the other; a managed key's
/// picker is disabled, as on the Settings page. No new setting and no default changes here.
@MainActor
public final class HomeChiefChatLookRows: NSObject {
    /// The Bubble Style picker.
    public let style = ThemedPopUpButton(frame: .zero, pullsDown: false)
    /// The Chat Colors button.
    public let colors = NSButton()
    private let settings: @MainActor @Sendable () -> SettingsController?
    private let openColors: @MainActor () -> Void
    /// The settings watch, in a lock so the nonisolated deinit can cancel it without a main-actor hop.
    private let watch = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// What the style row shows: the style id and whether the key is managed.
    public nonisolated struct Shown: Equatable, Sendable {
        /// The style id (`imessage` or `theme`).
        public var style: String
        /// The key is managed: the picker is disabled.
        public var managed: Bool
    }

    /// - Parameters:
    ///   - settings: the app's settings (nil before they load: the row shows the default).
    ///   - openColors: opens Chat Colors… for the popover's Chief chat.
    public init(settings: @escaping @MainActor @Sendable () -> SettingsController?, openColors: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.openColors = openColors
        super.init()
        style.font = Typography.body
        style.target = self
        style.action = #selector(picked)
        style.setAccessibilityIdentifier("cmux.home.chief.bubbleStyle")
        for choice in Self.choices {
            style.addItem(withTitle: choice.title)
            style.lastItem?.representedObject = choice.value
        }
        colors.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: HomeChatColorsStrings.title)
        colors.imagePosition = .imageOnly
        colors.bezelStyle = .push
        colors.controlSize = .small
        colors.target = self
        colors.action = #selector(chatColors)
        colors.toolTip = HomeChatColorsStrings.title
        colors.setAccessibilityLabel(HomeChatColorsStrings.title)
        colors.setAccessibilityIdentifier("cmux.home.chief.chatColors")
    }

    // The watch ends with the rows (their Home view). The lock is a Sendable let, so cancelling needs no main-actor hop.
    nonisolated deinit { watch.withLock { $0?.cancel() } }

    /// Bubble Style's title and choices, from the setting's own descriptor (Settings shows the same words).
    public static var title: String { SettingsSchema.descriptor(for: HomeChiefBubbleStyleSetting.configPath)?.title ?? "" }
    public static var choices: [SettingChoice] {
        guard case .choice(let choices)? = SettingsSchema.descriptor(for: HomeChiefBubbleStyleSetting.configPath)?.kind else { return [] }
        return choices
    }

    /// Adds Bubble Style and Chat Colors through `addRow` (the popover's Appearance section), then
    /// follows the setting while the rows live.
    public func install(addRow: (String, NSView) -> Void) {
        addRow(Self.title, style)
        addRow(HomeChatColorsStrings.title, colors)
        let settings = settings
        // task-owner: `watch`, as long as the rows (their Home view; deinit cancels it); event-driven (Observation)
        let task = Task { [weak self] in
            for await shown in ObservationStream({ ObservationTrigger(Self.shown(settings())) }) {
                guard let self, !Task.isCancelled else { return }
                show(shown.value)
            }
        }
        watch.withLock { $0?.cancel(); $0 = task }
        show(Self.shown(settings()))
    }

    /// The style the settings hold now (the default before they load) and whether it is managed.
    public static func shown(_ settings: SettingsController?) -> Shown {
        guard let settings else { return Shown(style: HomeChiefBubbleStyleSetting.fallback.rawValue, managed: false) }
        return Shown(style: settings.snapshot.homeChiefBubbleStyle,
                     managed: settings.managedKeys[HomeChiefBubbleStyleSetting.key] != nil)
    }

    public func show(_ shown: Shown) {
        if let index = style.itemArray.firstIndex(where: { $0.representedObject as? String == shown.style }) {
            style.selectItem(at: index)
        }
        style.isEnabled = !shown.managed
    }

    @objc public func picked() {
        guard let value = style.selectedItem?.representedObject as? String, let settings = settings() else { return }
        // task-owner: one settings write; ends with it
        Task { [weak self] in
            do {
                try await settings.setSetting(at: HomeChiefBubbleStyleSetting.configPath, to: .string(value), by: .user)
            } catch {
                NSSound.beep()
                self?.show(Self.shown(settings))
            }
        }
    }

    @objc public func chatColors() { openColors() }
}
