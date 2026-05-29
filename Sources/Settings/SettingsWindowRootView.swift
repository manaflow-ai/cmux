import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct SettingsWindowRootView: View {
    @State private var draftState = SettingsDraftState()
    @State private var windowReference = WeakSettingsWindowReference()
    @State private var shouldRenderSettingsContent = true

    var body: some View {
        Group {
            if shouldRenderSettingsContent {
                SettingsRootView(draftState: draftState)
            } else {
                Color.clear
                    .frame(
                        minWidth: SettingsWindowPresenter.minimumSize.width,
                        minHeight: SettingsWindowPresenter.minimumSize.height
                    )
            }
        }
        .background(WindowAccessor { window in
            windowReference.window = window
            SettingsWindowPresenter.configure(window: window)
            setContentVisibility(!window.isMiniaturized)
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(false)
            windowReference.window = nil
        }
    }

    private func isObservedWindow(_ object: Any?) -> Bool {
        guard
            let notificationWindow = object as? NSWindow,
            let window = windowReference.window
        else {
            return false
        }
        return notificationWindow === window
    }

    private func setContentVisibility(_ isVisible: Bool) {
        guard shouldRenderSettingsContent != isVisible else { return }
        shouldRenderSettingsContent = isVisible
    }
}
