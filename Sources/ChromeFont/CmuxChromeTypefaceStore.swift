import CmuxFoundation
import CmuxSettings
import CmuxTerminalCore
import Combine
import SwiftUI

/// App-wide resolution of the `app.chromeFont` setting.
///
/// The sidebar resolves the same typeface inside
/// ``SidebarTabItemSettingsSnapshot`` because its rows need it inside a value
/// snapshot that AppKit cells can measure from. Every other chrome surface
/// (surface tabs, the Cloud panel, the chrome pills) draws through
/// `.cmuxFont`, so it only needs the environment value, which this store
/// publishes. Both paths call the same
/// ``CmuxChromeFont/resolvedTypeface(source:terminalFamilies:isInstalled:)``,
/// so they cannot disagree.
@MainActor
final class CmuxChromeTypefaceStore: ObservableObject {
    static let shared = CmuxChromeTypefaceStore()

    @Published private(set) var typeface: CmuxChromeTypeface

    private let defaults: UserDefaults
    private var terminalFontFamilies: [String]
    private var loadTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var chromeFontFamilyObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        terminalFontFamilies: [String] = []
    ) {
        self.defaults = defaults
        self.terminalFontFamilies = terminalFontFamilies
        typeface = Self.resolve(defaults: defaults, terminalFontFamilies: terminalFontFamilies)
        defaultsObserver = NotificationCenter.default.addUserDefaultsObserver(object: nil) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        // A Ghostty config reload that changes `font-family` moves the chrome
        // with it, the same way it already moves the sidebar's font size.
        chromeFontFamilyObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyChromeFontFamilyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadTerminalFontFamilies()
            }
        }
        reloadTerminalFontFamilies()
    }

    deinit {
        loadTask?.cancel()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let chromeFontFamilyObserver {
            NotificationCenter.default.removeObserver(chromeFontFamilyObserver)
        }
    }

    private func reloadTerminalFontFamilies() {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            // Reading the Ghostty config touches the filesystem, so it stays
            // off the main actor exactly as the sidebar's own read does.
            let families = await Task.detached(priority: .utility) {
                GhosttyConfig.loadForCmux().effectiveFontFamilies
            }.value
            guard let self, !Task.isCancelled else { return }
            terminalFontFamilies = families
            refresh()
        }
    }

    private func refresh() {
        let next = Self.resolve(defaults: defaults, terminalFontFamilies: terminalFontFamilies)
        guard next != typeface else { return }
        typeface = next
    }

    private static func resolve(
        defaults: UserDefaults,
        terminalFontFamilies: [String]
    ) -> CmuxChromeTypeface {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        return CmuxChromeTypeface.resolved(
            source: CmuxChromeFontSource(
                settingValue: settings.value(for: AppCatalogSection().chromeFont)
            ),
            terminalFamilies: terminalFontFamilies
        )
    }
}

/// Draws this subtree's `.cmuxFont` text in the typeface the `app.chromeFont`
/// setting resolves to.
///
/// Attach it once per chrome surface root rather than at the app root: the
/// setting is meant for chrome that sits beside a terminal, not for settings
/// forms and dialogs.
struct CmuxChromeTypefaceFromSettings: ViewModifier {
    @ObservedObject private var store = CmuxChromeTypefaceStore.shared

    func body(content: Content) -> some View {
        content.cmuxChromeTypeface(store.typeface)
    }
}

extension View {
    /// Applies the resolved `app.chromeFont` typeface to this chrome surface.
    func cmuxChromeTypefaceFromSettings() -> some View {
        modifier(CmuxChromeTypefaceFromSettings())
    }
}
