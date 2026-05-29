import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

@MainActor
final class WeakSettingsWindowReference {
    weak var window: NSWindow?
}

@MainActor
@Observable
final class SettingsDraftState {
    var browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
    var browserInsecureHTTPAllowlistSyncedValue = BrowserInsecureHTTPSettings.defaultAllowlistText
    var socketPasswordDraft = ""
    var settingsColumnVisibility: NavigationSplitViewVisibility = .all
    var settingsSearchText = ""

    func syncBrowserInsecureHTTPAllowlistFromSavedValue(_ savedValue: String) {
        if browserInsecureHTTPAllowlistDraft == browserInsecureHTTPAllowlistSyncedValue {
            browserInsecureHTTPAllowlistDraft = savedValue
        }
        browserInsecureHTTPAllowlistSyncedValue = savedValue
    }
}
