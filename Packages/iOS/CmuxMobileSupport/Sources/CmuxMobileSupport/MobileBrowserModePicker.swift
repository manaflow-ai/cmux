#if canImport(UIKit)
public import SwiftUI
import UIKit

/// How a browser surface shows pages.
public enum MobileBrowserMode: Hashable, Sendable {
    /// The computer's (or Mac's) real browser, streamed as video.
    case streamed
    /// WebKit on this device, loading pages through the computer.
    case onDevice
}

/// The Streamed / On iPhone switch in ``MobileBrowserChromeBar``.
public struct MobileBrowserModePicker {
    /// The mode this browser is in.
    public var current: MobileBrowserMode
    /// Modes that cannot be chosen now, with a one-line reason shown under
    /// the dimmed menu item.
    public var unavailable: [MobileBrowserMode: String]
    /// Switches this browser to another mode.
    public var select: (MobileBrowserMode) -> Void

    public init(
        current: MobileBrowserMode,
        unavailable: [MobileBrowserMode: String] = [:],
        select: @escaping (MobileBrowserMode) -> Void
    ) {
        self.current = current
        self.unavailable = unavailable
        self.select = select
    }

    /// "On iPhone" / "On iPad".
    public static var onDeviceTitle: String {
        UIDevice.current.userInterfaceIdiom == .pad
            ? L10n.string("mobile.browser.mode.onIPad", defaultValue: "On iPad")
            : L10n.string("mobile.browser.mode.onIPhone", defaultValue: "On iPhone")
    }

    static var streamedTitle: String {
        L10n.string("mobile.browser.mode.streamed", defaultValue: "Streamed")
    }

    static func detail(_ mode: MobileBrowserMode) -> String {
        switch mode {
        case .streamed:
            L10n.string("mobile.browser.mode.streamed.detail", defaultValue: "The computer's own browser")
        case .onDevice:
            L10n.string("mobile.browser.mode.onDevice.detail", defaultValue: "Loads here, through the computer")
        }
    }
}

/// A small menu button: a checkmarked choice between the two modes, with an
/// unavailable one dimmed and its reason as the subtitle.
struct MobileBrowserModeMenu: View {
    let picker: MobileBrowserModePicker

    var body: some View {
        Menu {
            row(.streamed, title: MobileBrowserModePicker.streamedTitle)
            row(.onDevice, title: MobileBrowserModePicker.onDeviceTitle)
        } label: {
            Image(systemName: picker.current == .streamed ? "play.display" : "iphone")
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("mobile.browser.mode.menu", defaultValue: "Browser Mode"))
        .accessibilityValue(picker.current == .streamed
            ? MobileBrowserModePicker.streamedTitle
            : MobileBrowserModePicker.onDeviceTitle)
        .accessibilityIdentifier("MobileBrowserModeMenu")
    }

    private func row(_ mode: MobileBrowserMode, title: String) -> some View {
        let reason = picker.unavailable[mode]
        return Toggle(isOn: Binding(
            get: { picker.current == mode },
            set: { isOn in if isOn, mode != picker.current { picker.select(mode) } }
        )) {
            Text(title)
            Text(reason ?? MobileBrowserModePicker.detail(mode))
        }
        .disabled(reason != nil && mode != picker.current)
        .accessibilityIdentifier(mode == .streamed ? "MobileBrowserModeStreamed" : "MobileBrowserModeOnDevice")
    }
}
#endif
