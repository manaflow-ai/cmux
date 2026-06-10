import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - Build Flavor
nonisolated enum BuildFlavor: String, Sendable {
    case dev
    case nightly
    case stable

    static var current: BuildFlavor {
        let bundle = Bundle.main
        return detect(
            bundleNames: [
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                ProcessInfo.processInfo.processName,
            ].compactMap { $0 },
            bundleIdentifier: bundle.bundleIdentifier
        )
    }

    static func detect(bundleName: String?, bundleIdentifier: String?) -> BuildFlavor {
        detect(bundleNames: [bundleName].compactMap { $0 }, bundleIdentifier: bundleIdentifier)
    }

    static func detect(bundleNames: [String], bundleIdentifier: String?) -> BuildFlavor {
        if bundleNames.contains(where: containsDevToken) {
            return .dev
        }

        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if SocketControlSettings.isDebugLikeBundleIdentifier(normalizedBundleIdentifier) {
            return .dev
        }
        if normalizedBundleIdentifier == "com.cmuxterm.app.nightly"
            || normalizedBundleIdentifier?.hasPrefix("com.cmuxterm.app.nightly.") == true {
            return .nightly
        }
        if bundleNames.contains(where: containsNightlyToken) {
            return .nightly
        }
        return .stable
    }

    private static func containsDevToken(_ name: String) -> Bool {
        containsToken("DEV", in: name)
    }

    private static func containsNightlyToken(_ name: String) -> Bool {
        containsToken("NIGHTLY", in: name)
    }

    private static func containsToken(_ token: String, in name: String) -> Bool {
        name
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { String($0) == token }
    }
}

